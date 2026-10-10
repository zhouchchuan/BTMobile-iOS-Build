#ifndef BT_MOBILE_HOST_TEST
#include <napi/native_api.h>
#endif
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/load_torrent.hpp>
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
#ifdef BTMOBILE_OHOS
#include "ohos_network.hpp"
#include <hilog/log.h>
#endif
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
    int btListenPort = 6882;
    json networkSettings = {{"listenPort",6882},{"dht",true},{"lsd",true},{"natPmp",true},{"upnp",true},{"utp",true}};
    static std::string listenAddresses(int value) {
        return "0.0.0.0:" + std::to_string(value) + ",[::]:" + std::to_string(value);
    }
    json validatedSettings(json const& changes) const {
        if (!changes.is_object()) throw std::runtime_error("网络设置格式无效");
        json result = networkSettings;
        for (auto const& key : {"listenPort","dht","lsd","natPmp","upnp","utp"}) {
            if (changes.contains(key)) result[key] = changes.at(key);
        }
        if (!result["listenPort"].is_number_integer()) throw std::runtime_error("BT 端口必须是整数");
        auto value = result["listenPort"].get<int64_t>();
        if (value < 1024 || value > 65535) throw std::runtime_error("BT 端口必须在 1024 到 65535 之间");
        for (auto const& key : {"dht","lsd","natPmp","upnp","utp"}) if (!result[key].is_boolean()) throw std::runtime_error("网络开关必须是布尔值");
        return result;
    }
    lt::settings_pack settingsPack() const {
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, listenAddresses(btListenPort));
        settings.set_bool(lt::settings_pack::enable_dht, networkSettings.at("dht"));
        settings.set_bool(lt::settings_pack::enable_lsd, networkSettings.at("lsd"));
        settings.set_bool(lt::settings_pack::enable_natpmp, networkSettings.at("natPmp"));
        settings.set_bool(lt::settings_pack::enable_upnp, networkSettings.at("upnp"));
        settings.set_bool(lt::settings_pack::enable_incoming_utp, networkSettings.at("utp"));
        settings.set_bool(lt::settings_pack::enable_outgoing_utp, networkSettings.at("utp"));
        return settings;
    }
    void appendDefaultTrackers(lt::add_torrent_params& params) const {
        // Keep explicit/private tracker URLs and order; append missing defaults.
        for (auto const& url : trackers) if (std::find(params.trackers.begin(), params.trackers.end(), url) == params.trackers.end()) {
            params.trackers.push_back(url);
            params.tracker_tiers.resize(params.trackers.size(), 0);
        }
    }
    std::string listenError, trackerError;
    int trackerReplies = 0, trackerPeers = 0, metadataReceived = 0;
    struct DhtSample { int nodes; std::chrono::steady_clock::time_point time; };
    std::map<std::string, DhtSample> dhtSamples;
#ifdef BTMOBILE_OHOS
    btmobile_ohos::Network network;
    std::string networkIdentity;
    int networkRetries = 0;
    std::chrono::steady_clock::time_point nextNetworkRetry{};
#endif
    static void diagnosticLog(std::string const& text) {
#ifdef BTMOBILE_OHOS
        // No magnet URIs, hashes, filenames, tracker tokens or device IDs.
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x1201, "BTMobileCore", "%{public}s", text.c_str());
#else
        (void)text;
#endif
    }
    int dhtNodes() const {
        int nodes = 0; auto now = std::chrono::steady_clock::now();
        for (auto const& sample : dhtSamples) if (now - sample.second.time < 30s) nodes += sample.second.nodes;
        return nodes;
    }
    void checkNetwork() {
#ifdef BTMOBILE_OHOS
        auto updated = btmobile_ohos::snapshot();
        auto now = std::chrono::steady_clock::now();
        bool changed = updated.code == 0 && updated.identity != networkIdentity;
        bool lost = updated.code == -1 && !networkIdentity.empty();
        network = std::move(updated);
        if (changed || lost || (network.code == 0 && !session->is_listening() && now >= nextNetworkRetry)) {
            networkIdentity = network.code == 0 ? network.identity : "";
            nextNetworkRetry = now + 30s; ++networkRetries;
            dhtSamples.clear(); listenError.clear();
            session->reopen_network_sockets();
            if (network.code == 0) for (auto const& item : tasks) {
                if (item.second.status().flags & lt::torrent_flags::paused) continue;
                item.second.force_reannounce(); item.second.force_dht_announce();
            }
            diagnosticLog("network recovery: code=" + std::to_string(network.code) + " interfaces=" + std::to_string(network.interfaces.size()) + " routes=" + std::to_string(network.routes.size()));
        }
#endif
    }
    json diagnostics() {
        json result = {{"listening",session->is_listening()},{"listenPort",session->listen_port()},{"configuredPort",btListenPort},
            {"dhtNodes",dhtNodes()},{"trackerReplies",trackerReplies},{"trackerPeers",trackerPeers},
            {"metadataReceived",metadataReceived},{"listenError",listenError},{"trackerError",trackerError}};
#ifdef BTMOBILE_OHOS
        result["networkCode"] = network.code;
        result["interfaces"] = network.interfaces.size(); result["routes"] = network.routes.size();
        result["recoveries"] = networkRetries;
#endif
        return result;
    }
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
            if (auto failed = lt::alert_cast<lt::listen_failed_alert>(a)) {
                listenError = "网络监听失败：" + failed->error.message() + " (" + std::to_string(failed->error.value()) + ", op=" + std::to_string(static_cast<int>(failed->op)) + ")";
                diagnosticLog(listenError);
            } else if (lt::alert_cast<lt::listen_succeeded_alert>(a)) {
                diagnosticLog("BT listener ready");
            } else if (auto reply = lt::alert_cast<lt::tracker_reply_alert>(a)) {
                ++trackerReplies; trackerPeers += reply->num_peers;
            } else if (auto failed = lt::alert_cast<lt::tracker_error_alert>(a)) {
                trackerError = "最近 Tracker 错误：" + failed->error.message() + " (" + std::to_string(failed->error.value()) + ")";
            } else if (lt::alert_cast<lt::metadata_received_alert>(a)) {
                ++metadataReceived; diagnosticLog("magnet metadata received");
            } else if (auto stats = lt::alert_cast<lt::dht_stats_alert>(a)) {
                int nodes = 0; for (auto const& bucket : stats->routing_table) nodes += bucket.num_nodes;
                dhtSamples[stats->local_endpoint.address().to_string()] = {nodes, std::chrono::steady_clock::now()};
            }
            if (auto s = lt::alert_cast<lt::save_resume_data_alert>(a)) {
                if (!s->handle.is_valid() || !tasks.count(id(s->handle))) continue;
                auto data = lt::write_resume_data_buf(s->params);
                auto destination = root / ".state" / (id(s->handle) + ".resume");
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
        auto ahead = std::min(files.map_file(ix, aheadOffset, 1).piece, first + lt::piece_index_t::diff_type(127));
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
            try {
                std::ifstream input(root / ".state" / "network.json");
                if (input) { json saved; input >> saved; networkSettings = validatedSettings(saved); btListenPort = networkSettings.at("listenPort"); }
            } catch (...) { diagnosticLog("invalid saved network settings; using defaults"); }
            lt::settings_pack settings = settingsPack();
            settings.set_str(lt::settings_pack::user_agent, "Htorrent/0.1.1");
            settings.set_str(lt::settings_pack::peer_fingerprint, "-HT0110-");
            // Do not silently drift to another configured port on conflict.
            settings.set_int(lt::settings_pack::max_retry_port_bind, 0);
            settings.set_bool(lt::settings_pack::listen_system_port_fallback, false);
            settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::status | lt::alert_category::tracker | lt::alert_category::dht)));
            settings.set_str(lt::settings_pack::dht_bootstrap_nodes, "router.bittorrent.com:6881,router.utorrent.com:6881,dht.transmissionbt.com:6881");
#ifdef BTMOBILE_OHOS
            network = btmobile_ohos::snapshot(); networkIdentity = network.identity;
            nextNetworkRetry = std::chrono::steady_clock::now() + 30s;
            diagnosticLog("NetworkKit init: code=" + std::to_string(network.code) + " interfaces=" + std::to_string(network.interfaces.size()) + " routes=" + std::to_string(network.routes.size()));
#endif
            session = std::make_unique<lt::session>(settings);
            for (auto const& file : fs::directory_iterator(root / ".state")) {
                if (file.path().extension() != ".resume") continue;
                try {
                    std::ifstream f(file.path(), std::ios::binary); std::vector<char> bytes((std::istreambuf_iterator<char>(f)),{});
                    lt::error_code ec; auto params = lt::read_resume_data(bytes, ec); if (ec) continue;
                    params.save_path = root.string(); params.flags &= ~lt::torrent_flags::auto_managed;
                    appendDefaultTrackers(params);
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
                        if (tick % 5 == 0) { checkNetwork(); session->post_dht_stats(); }
                        if (tick % 30 == 0) diagnosticLog("listening=" + std::to_string(session->is_listening()) + " dht_nodes=" + std::to_string(dhtNodes()) + " tracker_replies=" + std::to_string(trackerReplies) + " metadata=" + std::to_string(metadataReceived));
                    } catch (...) { diagnosticLog("core maintenance failed; retry on next tick"); }
                    std::this_thread::sleep_for(1s);
                }
            });
            return {{"ok",true},{"version",LIBTORRENT_VERSION}};
        }
        if (!session) throw std::runtime_error("下载核心尚未启动");
        if (op == "getNetworkSettings") {
            std::lock_guard<std::mutex> l(mutex);
            return {{"settings",networkSettings}};
        }
        if (op == "setListenPort" || op == "setNetworkSettings") {
            // Stable settings API: partial updates, validation, atomic persistence.
            // Reconfigure libtorrent in place, never replace the active session.
            std::lock_guard<std::mutex> l(mutex);
            auto updated = validatedSettings(op == "setListenPort" ? json{{"listenPort",j.at("port")}} : j.at("settings"));
            if (updated != networkSettings) {
                auto path = root / ".state" / "network.json";
                std::ofstream out(path.string() + ".tmp"); out << updated.dump(); out.close();
                if (!out) throw std::runtime_error("无法保存 BT 网络设置");
                fs::rename(path.string() + ".tmp", path);
                bool portChanged = updated.at("listenPort") != networkSettings.at("listenPort");
                networkSettings = updated; btListenPort = updated.at("listenPort");
                if (portChanged) listenError.clear();
                if (portChanged || !networkSettings.at("dht").get<bool>()) dhtSamples.clear();
                session->apply_settings(settingsPack());
            }
            return {{"ok",true},{"port",btListenPort},{"settings",networkSettings}};
        }
        if (op == "add") {
            lt::error_code ec; std::string uri = j.at("uri"); lt::add_torrent_params p;
            if (uri.rfind("magnet:?",0) == 0) p = lt::parse_magnet_uri(uri,ec);
            else p = lt::load_torrent_file(checked(uri).string());
            if (ec) throw std::runtime_error("磁力链接或种子文件无效");
            p.save_path = root.string(); p.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
            appendDefaultTrackers(p);
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
            return {{"items",list},{"network",diagnostics()}};
        }
        if (op == "pause" || op == "resume") {
            auto h = task(j); h.unset_flags(lt::torrent_flags::auto_managed);
            if (op == "pause") h.pause(); else h.resume();
            h.save_resume_data(lt::torrent_handle::save_info_dict); return {{"ok",true}};
        }
        if (op == "remove") {
            auto h=task(j); auto key=id(h);
            std::lock_guard<std::mutex> l(mutex);
            for(auto it=streams.begin();it!=streams.end();) {
                if(it->second->handle==h){restorePriorities(it->second);it=streams.erase(it);}else ++it;
            }
            tasks.erase(key);session->remove_torrent(h); // Keep user payload files.
            fs::remove(root/".state"/(key+".resume"));
            fs::remove(root/".state"/(key+".resume.tmp"));
            return {{"ok",true}};
        }
        if (op == "peers") {
            auto h=task(j);std::vector<lt::peer_info> peers;h.get_peer_info(peers);json list=json::array();
            for(auto const& p:peers)list.push_back({{"address",p.remote_endpoint().address().to_string()+":"+std::to_string(p.remote_endpoint().port())},{"client",p.client},{"download",p.payload_down_speed},{"upload",p.payload_up_speed},{"progress",p.progress}});
            return {{"items",list}};
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
        if (op == "compress") {
            int expected = -1;
            if (!archiveProgress.compare_exchange_strong(expected, 0)) throw std::runtime_error("已有压缩或解压任务正在进行");
            struct Reset { std::atomic<int>& p; ~Reset(){p=-1;} } reset{archiveProgress};
            cancelArchive=false;
            auto source=checked(j.at("path")), output=checked(j.at("output"));
            if (fs::exists(output)) throw std::runtime_error("输出文件已存在");
            if (source==root || fs::is_symlink(source)) throw std::runtime_error("不能压缩此路径");
            std::vector<fs::path> inputs;
            if(fs::is_directory(source)) {
                for(auto const& item:fs::recursive_directory_iterator(source)) {
                    if(fs::is_symlink(item)) throw std::runtime_error("为安全起见，不压缩符号链接");
                    if(item.is_regular_file()) inputs.push_back(item.path());
                }
            } else inputs.push_back(source);
            uint64_t total=0,done=0;for(auto const& p:inputs)total+=fs::file_size(p);
            auto writer=archive_write_new();
            struct Writer { archive* a; ~Writer(){archive_write_free(a);} } cleanup{writer};
            archive_write_set_format_zip(writer);
            if(archive_write_open_filename(writer,output.c_str())!=ARCHIVE_OK)throw std::runtime_error("无法创建 ZIP 文件");
            for(auto const& p:inputs) {
                auto entry=archive_entry_new();
                std::string name=p.lexically_relative(source.parent_path()).generic_string();
                archive_entry_set_pathname(entry,name.c_str());archive_entry_set_size(entry,fs::file_size(p));
                archive_entry_set_filetype(entry,AE_IFREG);archive_entry_set_perm(entry,0600);
                int status=archive_write_header(writer,entry);archive_entry_free(entry);
                if(status!=ARCHIVE_OK)throw std::runtime_error("ZIP 文件头写入失败");
                std::ifstream f(p,std::ios::binary);char buffer[65536];
                while(f) {
                    if(cancelArchive)throw std::runtime_error("压缩已取消，已保留部分文件");
                    f.read(buffer,sizeof buffer);auto count=f.gcount();if(count<=0)break;
                    if(archive_write_data(writer,buffer,count)!=count)throw std::runtime_error("写入失败，请检查剩余空间");
                    done+=count;archiveProgress=total?int(done*100/total):0;
                }
                if(f.bad())throw std::runtime_error("读取源文件失败");
            }
            if(archive_write_close(writer)!=ARCHIVE_OK)throw std::runtime_error("ZIP 文件保存失败");
            return {{"ok",true}};
        }
        if (op == "extract") return extract(j);
        if (op == "archiveProgress") return {{"percent",archiveProgress.load()}};
        if (op == "cancelArchive") { cancelArchive=true; return {{"ok",true}}; }
        throw std::runtime_error("未知操作");
    }
};

#ifndef BT_MOBILE_HOST_TEST
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
#endif
