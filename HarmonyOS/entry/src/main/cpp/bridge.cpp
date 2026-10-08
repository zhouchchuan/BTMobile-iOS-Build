#include <napi/native_api.h>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/version.hpp>
#include <archive.h>
#include <archive_entry.h>
#include <openssl/rand.h>
#include <nlohmann/json.hpp>
#include <httplib.h>
#include "range.hpp"
#include <fstream>
#include <mutex>
#include <thread>
#include <atomic>
#include <chrono>
#include <map>
#include <sys/stat.h>

namespace lt = libtorrent;
namespace fs = std::filesystem;
using json = nlohmann::json;
using namespace std::chrono_literals;

// Native calls run on the N-API worker pool. libtorrent owns its network thread.
class Core {
    std::mutex mutex;
    std::unique_ptr<lt::session> session;
    fs::path root;
    std::map<std::string, lt::torrent_handle> tasks;
    httplib::Server http;
    std::thread httpThread, saveThread;
    std::atomic<bool> running{false};
    std::atomic<int> archiveProgress{-1};
    std::atomic<bool> cancelArchive{false};
    int port = 0;
    struct Stream {
        lt::torrent_handle handle;
        int index = 0;
        std::atomic<bool> active{true};
        std::mutex guard;
        std::map<lt::piece_index_t, lt::download_priority_t> priorities;
    };
    std::map<std::string, std::shared_ptr<Stream>> streams;
    const std::vector<std::string> trackers = {
        "http://tracker1.linkyou.win:6969/announce", "http://tracker2.linkyou.win:6969/announce",
        "http://tracker2v4.linkyou.win:6969/announce", "http://tracker2v6.linkyou.win:6969/announce",
        "udp://open.stealth.si:80/announce", "udp://retracker.hotplug.ru:2710/announce",
        "udp://tracker.torrent.eu.org:451/announce", "udp://tracker.tryhackx.org:6969/announce",
        "udp://www.torrent.eu.org:451/announce"
    };
    static std::string id(lt::torrent_handle const& h) {
        std::ostringstream s; s << h.info_hashes().get_best(); return s.str();
    }
    lt::torrent_handle task(json const& j) {
        std::lock_guard<std::mutex> lock(mutex);
        auto it = tasks.find(j.at("id").get<std::string>());
        if (it == tasks.end() || !it->second.is_valid()) throw std::runtime_error("任务不存在");
        return it->second;
    }
    fs::path checked(std::string const& path) {
        auto p = fs::weakly_canonical(root / path);
        auto relative = p.lexically_relative(root);
        if (relative.empty() || relative.is_absolute() || *relative.begin() == "..") throw std::runtime_error("不允许访问下载目录外的文件");
        return p;
    }
    void saveAlerts() {
        std::vector<lt::alert*> alerts; session->pop_alerts(&alerts);
        for (auto a : alerts) {
            if (auto s = lt::alert_cast<lt::save_resume_data_alert>(a)) {
                auto data = lt::write_resume_data_buf(s->params);
                auto destination = root / ".state" / (id(s->handle) + ".resume");
                if (!s->handle.is_valid()) continue;
                std::ofstream f(destination.string() + ".tmp", std::ios::binary);
                f.write(data.data(), data.size()); f.close();
                if (f) fs::rename(destination.string() + ".tmp", destination);
            }
        }
    }
    void restorePriorities(std::shared_ptr<Stream> const& stream) {
        stream->active = false;
        std::lock_guard<std::mutex> lock(stream->guard);
        if (!stream->handle.is_valid()) return;
        for (auto const& item : stream->priorities) {
            stream->handle.reset_piece_deadline(item.first);
            if (stream->handle.piece_priority(item.first) == lt::top_priority) stream->handle.piece_priority(item.first, item.second);
        }
        stream->priorities.clear();
    }
    bool ready(std::shared_ptr<Stream> const& s, int64_t offset, size_t count) {
        std::lock_guard<std::mutex> lock(s->guard);
        if (!s->active || !s->handle.is_valid()) return false;
        auto ti = s->handle.torrent_file(); if (!ti) return false;
        auto const& files = ti->layout(); auto ix = lt::file_index_t(s->index);
        auto first = files.map_file(ix, offset, 1).piece;
        auto last = files.map_file(ix, offset + count - 1, 1).piece;
        bool complete = true;
        for (auto p = first; p <= last; ++p) complete = complete && s->handle.have_piece(p);
        // Never restart a manually paused torrent to satisfy a player read.
        if (s->handle.status().flags & lt::torrent_flags::paused) return complete;
        auto aheadOffset = std::min(files.file_size(ix) - 1, offset + 32 * 1024 * 1024);
        auto ahead = files.map_file(ix, aheadOffset, 1).piece;
        for (auto it = s->priorities.begin(); it != s->priorities.end();) {
            if (it->first < first || it->first > ahead) {
                s->handle.reset_piece_deadline(it->first);
                if (s->handle.piece_priority(it->first) == lt::top_priority) s->handle.piece_priority(it->first, it->second);
                it = s->priorities.erase(it);
            } else ++it;
        }
        for (auto p = first; p <= ahead; ++p) {
            if (s->handle.have_piece(p)) continue;
            if (!s->priorities.count(p)) {
                s->priorities[p] = s->handle.piece_priority(p);
                s->handle.piece_priority(p, lt::top_priority);
                s->handle.set_piece_deadline(p, int(p - first) * 200);
            }
        }
        return complete;
    }
    void serve(httplib::Request const& req, httplib::Response& res) {
        std::shared_ptr<Stream> s;
        { std::lock_guard<std::mutex> lock(mutex); auto it = streams.find(req.path); if (it != streams.end()) s = it->second; }
        if (!s || !s->active || !s->handle.is_valid()) { res.status = 404; return; }
        auto ti = s->handle.torrent_file(); if (!ti) { res.status = 503; return; }
        auto const& files = ti->layout(); auto ix = lt::file_index_t(s->index);
        int64_t size = files.file_size(ix);
        // cpp-httplib applies RFC ranges to a full-length provider; validate first.
        auto range = parseRange(req.get_header_value("Range"), size);
        if (!range) { res.status = 416; res.set_header("Content-Range", "bytes */" + std::to_string(size)); return; }
        auto path = files.file_path(ix, s->handle.status().save_path);
        res.set_header("Accept-Ranges", "bytes");
        res.set_header("Cache-Control", "no-store");
        res.set_content_provider(size, "application/octet-stream", [this, s, path](size_t offset, size_t length, httplib::DataSink& sink) {
            size_t count = std::min(size_t(64 * 1024), length);
            auto until = std::chrono::steady_clock::now() + 90s;
            while (s->active && running && !ready(s, offset, count)) {
                if (!sink.is_writable() || std::chrono::steady_clock::now() >= until) return false;
                std::this_thread::sleep_for(80ms);
            }
            if (!s->active || !running) return false;
            std::ifstream input(path, std::ios::binary); input.seekg(offset);
            std::string bytes(count, '\0'); input.read(bytes.data(), count);
            if (size_t(input.gcount()) != count) return false;
            return sink.write(bytes.data(), bytes.size());
        });
    }
    json extract(json const& j) {
        int expected = -1;
        if (!archiveProgress.compare_exchange_strong(expected, 0)) throw std::runtime_error("已有解压任务正在进行");
        struct Reset { std::atomic<int>& p; ~Reset() { p = -1; } } reset{archiveProgress};
        cancelArchive = false;
        auto source = checked(j.at("path"));
        auto destination = checked(j.at("output"));
        if (fs::exists(destination)) throw std::runtime_error("目标目录已存在，请使用新的目录名称");
        fs::create_directories(destination);
        auto reader = archive_read_new();
        struct Reader { archive* a; ~Reader(){ archive_read_free(a); } } cleanup{reader};
        archive_read_support_filter_all(reader); archive_read_support_format_all(reader);
        std::string password = j.value("password", "");
        if (!password.empty()) archive_read_add_passphrase(reader, password.c_str());
        auto failure = [&]() -> std::runtime_error {
            std::string message = archive_error_string(reader) ? archive_error_string(reader) : "";
            std::transform(message.begin(), message.end(), message.begin(), [](unsigned char c){return std::tolower(c);});
            if (message.find("password") != message.npos || message.find("passphrase") != message.npos || message.find("encrypted") != message.npos)
                return std::runtime_error(password.empty() ? "此压缩包已加密，请输入密码后重试" : "密码错误或加密格式暂不支持，请检查密码");
            return std::runtime_error("解压失败：文件损坏、分卷缺失或此格式暂不支持");
        };
        if (archive_read_open_filename(reader, source.c_str(), 65536) != ARCHIVE_OK) throw failure();
        archive_entry* entry = nullptr;
        int result; auto sourceSize = fs::file_size(source);
        while ((result = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
            if (cancelArchive) throw std::runtime_error("解压已取消，已保留部分文件");
            std::string name = archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "";
            if (!safeArchivePath(name) || archive_entry_symlink(entry) || archive_entry_hardlink(entry)) throw std::runtime_error("压缩包含有不安全路径，已停止解压");
            auto output = destination / name;
            if (archive_entry_filetype(entry) == AE_IFDIR) fs::create_directories(output);
            else if (archive_entry_filetype(entry) == AE_IFREG) {
                fs::create_directories(output.parent_path());
                std::ofstream f(output, std::ios::binary); char buffer[65536]; la_ssize_t n;
                while ((n = archive_read_data(reader, buffer, sizeof buffer)) > 0) {
                    if (cancelArchive) throw std::runtime_error("解压已取消，已保留部分文件");
                    f.write(buffer, n); if (!f) throw std::runtime_error("无法写入文件，请检查剩余空间");
                    archiveProgress = sourceSize ? std::min(99LL, archive_filter_bytes(reader, -1) * 100 / static_cast<long long>(sourceSize)) : 0;
                }
                if (n < 0) throw failure();
            } else throw std::runtime_error("压缩包包含不支持的特殊文件");
        }
        if (result != ARCHIVE_EOF) throw failure();
        archiveProgress = 100; return {{"ok", true}};
    }
public:
    ~Core() { running = false; http.stop(); if (httpThread.joinable()) httpThread.join(); if (saveThread.joinable()) saveThread.join(); }
    json call(json const& j) {
        std::string op = j.at("op");
        if (op == "init") {
            std::lock_guard<std::mutex> lock(mutex);
            if (session) return {{"ok",true},{"version",LIBTORRENT_VERSION}};
            root = fs::weakly_canonical(j.at("root").get<std::string>()); fs::create_directories(root / ".state");
            lt::settings_pack settings;
            settings.set_str(lt::settings_pack::user_agent, "BTMobile-HarmonyOS/0.1.0");
            settings.set_str(lt::settings_pack::peer_fingerprint, "-BH0100-");
            settings.set_bool(lt::settings_pack::enable_dht, true);
            settings.set_bool(lt::settings_pack::enable_lsd, true);
            settings.set_bool(lt::settings_pack::enable_upnp, true);
            settings.set_bool(lt::settings_pack::enable_natpmp, true);
            settings.set_str(lt::settings_pack::dht_bootstrap_nodes, "router.bittorrent.com:6881,router.utorrent.com:6881,dht.transmissionbt.com:6881");
            session = std::make_unique<lt::session>(settings);
            for (auto const& file : fs::directory_iterator(root / ".state")) {
                if (file.path().extension() != ".resume") continue;
                try {
                    std::ifstream f(file.path(), std::ios::binary); std::vector<char> bytes((std::istreambuf_iterator<char>(f)),{});
                    lt::error_code ec; auto params = lt::read_resume_data(bytes, ec); if (ec) continue;
                    params.save_path = root.string(); params.flags &= ~lt::torrent_flags::auto_managed;
                    auto h = session->add_torrent(params, ec); if (!ec) tasks[id(h)] = h;
                } catch (...) { /* Corrupt resume files do not discard other tasks. */ }
            }
            http.Get(R"(/stream/.*)", [this](auto const& req, auto& res){ serve(req,res); });
            port = http.bind_to_any_port("127.0.0.1");
            if (port <= 0) throw std::runtime_error("无法启动本地播放服务");
            running = true;
            httpThread = std::thread([this]{ http.listen_after_bind(); });
            saveThread = std::thread([this]{
                int tick = 0;
                while(running) {
                    try {
                        std::lock_guard<std::mutex> l(mutex);
                        if (++tick % 15 == 0) for(auto const& item: tasks) item.second.save_resume_data(lt::torrent_handle::save_info_dict);
                        saveAlerts();
                    } catch (...) {}
                    std::this_thread::sleep_for(1s);
                }
            });
            return {{"ok",true},{"version",LIBTORRENT_VERSION}};
        }
        if (!session) throw std::runtime_error("下载核心尚未启动");
        if (op == "add") {
            lt::error_code ec; std::string uri = j.at("uri"); lt::add_torrent_params p;
            if (uri.rfind("magnet:?",0) == 0) p = lt::parse_magnet_uri(uri,ec);
            else p.ti = std::make_shared<lt::torrent_info>(checked(uri).string(), ec);
            if (ec) throw std::runtime_error("磁力链接或种子文件无效");
            p.save_path = root.string(); p.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
            p.trackers.insert(p.trackers.end(), trackers.begin(), trackers.end());
            std::lock_guard<std::mutex> l(mutex); auto h = session->add_torrent(p,ec);
            if (ec) throw std::runtime_error(ec.message());
            tasks[id(h)] = h; h.save_resume_data(lt::torrent_handle::save_info_dict);
            return {{"id",id(h)}};
        }
        if (op == "tasks") {
            json list = json::array(); std::lock_guard<std::mutex> l(mutex);
            for (auto const& item: tasks) {
                auto s = item.second.status(); bool paused = bool(s.flags & lt::torrent_flags::paused);
                list.push_back({{"id",item.first},{"name",s.name},{"progress",s.progress},{"download",s.download_payload_rate},{"upload",s.upload_payload_rate},{"peers",s.num_peers},{"paused",paused},{"state",paused ? "已暂停" : !s.has_metadata ? "获取元数据" : s.is_seeding ? "做种中" : "下载中"},{"error",s.errc ? s.errc.message() : ""}});
            }
            return {{"items",list}};
        }
        if (op == "pause" || op == "resume") {
            auto h = task(j); h.unset_flags(lt::torrent_flags::auto_managed);
            if (op == "pause") h.pause(); else h.resume();
            h.save_resume_data(lt::torrent_handle::save_info_dict); return {{"ok",true}};
        }
        if (op == "files") {
            auto h = task(j); auto ti = h.torrent_file(); json list=json::array();
            if (!ti) return {{"items",list}};
            auto const& f=ti->layout(); auto progress=h.file_progress();
            for (auto i:f.file_range()) list.push_back({{"index",int(i)},{"name",f.file_path(i)},{"size",f.file_size(i)},{"done",progress[int(i)]}});
            return {{"items",list}};
        }
        if (op == "stream") {
            auto h = task(j); auto ti=h.torrent_file(); int index=j.at("index");
            if (!ti || index < 0 || index >= ti->layout().num_files()) throw std::runtime_error("视频文件元数据未就绪");
            std::lock_guard<std::mutex> l(mutex);
            for(auto const& item: streams) restorePriorities(item.second); streams.clear();
            unsigned char bytes[24]; if(RAND_bytes(bytes,sizeof bytes)!=1) throw std::runtime_error("无法创建播放会话");
            const char* hex="0123456789abcdef"; std::string key="/stream/";
            for (auto b:bytes) {key+=hex[b>>4];key+=hex[b&15];}
            auto s=std::make_shared<Stream>(); s->handle=h; s->index=index; streams[key]=s;
            return {{"url","http://127.0.0.1:"+std::to_string(port)+key}};
        }
        if (op == "stopStream") {
            std::lock_guard<std::mutex> l(mutex); for(auto const& item: streams) restorePriorities(item.second); streams.clear(); return {{"ok",true}};
        }
        if (op == "resolve") {
            auto path=checked(j.at("path")); std::lock_guard<std::mutex> l(mutex);
            for (auto const& item:tasks) {
                auto ti=item.second.torrent_file(); if(!ti)continue;
                auto const& f=ti->layout(); auto progress=item.second.file_progress();
                for (auto i:f.file_range()) if (fs::weakly_canonical(f.file_path(i,root.string()))==path)
                    return {{"id",item.first},{"index",int(i)},{"complete",progress[int(i)]>=f.file_size(i)}};
            }
            return {{"id",""},{"complete",true}};
        }
        if (op == "extract") return extract(j);
        if (op == "archiveProgress") return {{"percent",archiveProgress.load()}};
        if (op == "cancelArchive") { cancelArchive=true; return {{"ok",true}}; }
        throw std::runtime_error("未知操作");
    }
};

static Core core;
struct Work { napi_async_work work; napi_deferred deferred; std::string request,result,error; };
static napi_value Invoke(napi_env env, napi_callback_info info) {
    size_t argc=1; napi_value args[1]; napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    napi_valuetype type; if (argc!=1 || napi_typeof(env,args[0],&type)!=napi_ok || type!=napi_string) { napi_throw_type_error(env,nullptr,"JSON request required"); return nullptr; }
    auto w=new Work(); size_t length=0; napi_get_value_string_utf8(env,args[0],nullptr,0,&length);
    if (length>1024*1024) {delete w;napi_throw_range_error(env,nullptr,"Request too large");return nullptr;}
    w->request.resize(length+1); napi_get_value_string_utf8(env,args[0],w->request.data(),length+1,&length); w->request.resize(length);
    napi_value promise,name; napi_create_promise(env,&w->deferred,&promise); napi_create_string_utf8(env,"BTMobile",NAPI_AUTO_LENGTH,&name);
    napi_create_async_work(env,nullptr,name,[](napi_env,void* data){
        auto w=static_cast<Work*>(data); try {w->result=core.call(json::parse(w->request)).dump();} catch(std::exception const& e){w->error=e.what();} catch(...){w->error="原生操作失败";}
    },[](napi_env env,napi_status status,void* data){
        auto w=static_cast<Work*>(data); napi_value value;
        if(status!=napi_ok || !w->error.empty()) {
            napi_value message; napi_create_string_utf8(env,w->error.empty()?"操作已取消":w->error.c_str(),NAPI_AUTO_LENGTH,&message); napi_create_error(env,nullptr,message,&value); napi_reject_deferred(env,w->deferred,value);
        } else {napi_create_string_utf8(env,w->result.c_str(),w->result.size(),&value);napi_resolve_deferred(env,w->deferred,value);}
        napi_delete_async_work(env,w->work);delete w;
    },w,&w->work); napi_queue_async_work(env,w->work); return promise;
}
static napi_value Init(napi_env env,napi_value exports) {
    napi_property_descriptor d={"invoke",nullptr,Invoke,nullptr,nullptr,nullptr,napi_default,nullptr}; napi_define_properties(env,exports,1,&d);return exports;
}
static napi_module module={1,0,nullptr,Init,"btmobile",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterBTMobile(){napi_module_register(&module);}
