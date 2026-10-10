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
#include <libtorrent/ip_filter.hpp>
#include <archive.h>
#include <archive_entry.h>
#include <openssl/rand.h>
#include <nlohmann/json.hpp>
#include <httplib.h>
#include "range.hpp"
#include "bt_settings.hpp"
#include "network_access.hpp"
#include "archive_engine.hpp"
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
#include <locale.h>

namespace lt = libtorrent;
namespace fs = std::filesystem;
using json = nlohmann::json;
using namespace std::chrono_literals;

// libarchive converts filenames via LC_CTYPE. Apply UTF-8 only to the
// file-operation worker, not to the process or libtorrent's threads.
struct Utf8Locale {
    locale_t current = newlocale(LC_CTYPE_MASK, "C.UTF-8", nullptr), previous = nullptr;
    Utf8Locale() { if (current) previous = uselocale(current); }
    ~Utf8Locale() { if (current) { uselocale(previous); freelocale(current); } }
};

// Native calls run on the N-API worker pool. libtorrent owns its network thread.
class Core {
    std::mutex mutex;
    std::mutex fileOperation;
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
    json networkSettings = btmobile::defaultSettings();
    bool networkBlocked = false;
    std::string allowedInterface;
    void evaluateNetworkAccess() {
        bool known = false, wifi = false, cellular = false, other = false;
#ifdef BTMOBILE_OHOS
        known = network.code == 0 && network.bearerKnown;
        wifi = network.wifi; cellular = network.cellular; other = network.otherBearer;
#endif
        bool allowWifi = networkSettings.at("allowWifi"), allowCellular = networkSettings.at("allowCellular");
        networkBlocked = !btmobile::transferAllowed(allowWifi, allowCellular, known, wifi, cellular, other);
        allowedInterface.clear();
#ifdef BTMOBILE_OHOS
        if (!networkBlocked && !(allowWifi && allowCellular)) allowedInterface = network.iface;
#endif
    }
    std::vector<std::string> managedTrackers = btmobile::defaultTrackers();
    std::int64_t managedRevision = 0;
    std::set<std::string> manuallyPaused;
    std::set<std::string> pendingDeletes;
    std::string deletionMessage;
    int deletionRevision = 0;
    std::set<std::string> completionArmed, completionSeen;
    json completionPending = json::object();
    void persistCompletions() {
        auto path = root / ".state" / "completions.json";
        std::ofstream out(path.string() + ".tmp");
        out << json{{"seen", completionSeen}, {"pending", completionPending}}.dump(); out.close();
        if (!out) throw std::runtime_error("无法保存下载完成事件");
        fs::rename(path.string() + ".tmp", path);
    }
    static std::string listenAddresses(int value) {
        return "0.0.0.0:" + std::to_string(value) + ",[::]:" + std::to_string(value);
    }
    json validatedSettings(json const& changes) const {
        return btmobile::validateSettings(networkSettings, changes);
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
        settings.set_int(lt::settings_pack::download_rate_limit, networkSettings.at("downloadLimitKiB").get<int>() * 1024);
        settings.set_int(lt::settings_pack::upload_rate_limit, networkSettings.at("uploadLimitKiB").get<int>() * 1024);
        bool queue = networkSettings.at("queueEnabled");
        settings.set_int(lt::settings_pack::active_limit, queue ? networkSettings.at("maxActive").get<int>() : -1);
        settings.set_int(lt::settings_pack::active_downloads, queue ? networkSettings.at("maxDownloads").get<int>() : -1);
        settings.set_int(lt::settings_pack::active_seeds, !networkSettings.at("seedEnabled").get<bool>() ? 0 : queue ? networkSettings.at("maxSeeds").get<int>() : -1);
        settings.set_bool(lt::settings_pack::dont_count_slow_torrents, false);
        settings.set_int(lt::settings_pack::auto_manage_interval, 1);
        // Session pause is independent from task manual/queue pause flags.
        settings.set_bool(lt::settings_pack::enable_incoming_tcp, !networkBlocked);
        settings.set_bool(lt::settings_pack::enable_outgoing_tcp, !networkBlocked);
        settings.set_str(lt::settings_pack::outgoing_interfaces, allowedInterface);
        if (!allowedInterface.empty()) settings.set_str(lt::settings_pack::listen_interfaces,
            allowedInterface + ":" + std::to_string(btListenPort));
        if (networkBlocked) {
            settings.set_str(lt::settings_pack::listen_interfaces, "");
            for (auto key : {lt::settings_pack::enable_dht, lt::settings_pack::enable_lsd,
                lt::settings_pack::enable_natpmp, lt::settings_pack::enable_upnp,
                lt::settings_pack::enable_incoming_utp, lt::settings_pack::enable_outgoing_utp}) settings.set_bool(key, false);
        }
        return settings;
    }
    void applyNetworkAccess() {
        if (networkBlocked) session->pause();
        session->apply_settings(settingsPack());
        if (!networkBlocked) session->resume();
    }
    bool managed() const { return networkSettings.at("queueEnabled").get<bool>() || !networkSettings.at("seedEnabled").get<bool>(); }
    void persistPauses() {
        auto path = root / ".state" / "manual-pauses.json";
        std::ofstream out(path.string()+".tmp"); out << json(manuallyPaused).dump(); out.close();
        if (!out) throw std::runtime_error("无法保存任务暂停状态");
        fs::rename(path.string()+".tmp",path);
    }
    void applyTaskPolicy(lt::torrent_handle const& handle) {
        if (manuallyPaused.count(id(handle))) {
            handle.unset_flags(lt::torrent_flags::auto_managed); handle.pause();
        } else if (managed()) {
            // The queue owns resumption. Never force all queued tasks active.
            handle.set_flags(lt::torrent_flags::auto_managed);
        } else {
            handle.unset_flags(lt::torrent_flags::auto_managed); handle.resume();
        }
    }
    void appendDefaultTrackers(lt::add_torrent_params& params) const {
        // Keep private torrents private, and preserve trackers supplied by the user.
        if ((params.ti && params.ti->priv()) || !networkSettings.at("autoAddTrackers").get<bool>()) return;
        auto urls = managedTrackers;
        for (auto const& custom : networkSettings.at("customTrackers")) urls.push_back(custom.get<std::string>());
        for (auto const& url : urls) if (std::find(params.trackers.begin(), params.trackers.end(), url) == params.trackers.end()) {
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
        bool wasBlocked = networkBlocked;
        auto previousInterface = allowedInterface;
        network = std::move(updated);
        evaluateNetworkAccess();
        if (networkBlocked != wasBlocked || allowedInterface != previousInterface) {
            applyNetworkAccess(); dhtSamples.clear();
            diagnosticLog(networkBlocked ? "BT transfer blocked by network preference" : "BT transfer allowed by network preference");
        }
        if (networkBlocked) { networkIdentity = network.identity; return; }
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
            {"metadataReceived",metadataReceived},{"listenError",listenError},{"trackerError",trackerError},
            {"networkBlocked",networkBlocked}};
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
        if (relative.empty() || relative == "." || relative.is_absolute() || *relative.begin() == ".." || *relative.begin() == ".state") throw std::runtime_error("不允许访问下载根目录、内部状态或下载目录外的文件");
        return p;
    }
    void ensureComplete(fs::path const& source) {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto const& task : tasks) {
            auto info = task.second.torrent_file(); if (!info) continue;
            auto const& layout = info->layout(); auto done = task.second.file_progress();
            for (auto i : layout.file_range()) if (fs::weakly_canonical(root / layout.file_path(i)) == source && done[int(i)] < layout.file_size(i))
                throw std::runtime_error("此文件尚未下载完整，请完成下载后再解压");
        }
    }
    void saveAlerts() {
        std::vector<lt::alert*> alerts; session->pop_alerts(&alerts);
        for (auto a : alerts) {
            // Arm only a genuine download transition. Checking/restoring an existing
            // complete file must not generate a fresh download-complete notification.
            if (auto changed = lt::alert_cast<lt::state_changed_alert>(a)) {
                if (changed->handle.is_valid() && changed->state == lt::torrent_status::downloading)
                    completionArmed.insert(id(changed->handle));
            }
            if (auto finished = lt::alert_cast<lt::torrent_finished_alert>(a)) {
                if (finished->handle.is_valid()) {
                    auto key = id(finished->handle);
                    if (tasks.count(key) && completionArmed.erase(key) && !completionSeen.count(key)) {
                        completionSeen.insert(key);
                        if (networkSettings.at("completionNotifications").get<bool>()) completionPending[key] = finished->handle.status().name;
                        persistCompletions();
                    }
                }
            }
            if (auto deleted = lt::alert_cast<lt::torrent_deleted_alert>(a)) {
                std::ostringstream key; key << deleted->info_hashes.get_best(); pendingDeletes.erase(key.str());
                deletionMessage = "任务下载数据已删除"; ++deletionRevision;
            } else if (auto failed = lt::alert_cast<lt::torrent_delete_failed_alert>(a)) {
                std::ostringstream key; key << failed->info_hashes.get_best(); pendingDeletes.erase(key.str());
                deletionMessage = "任务已移除，但数据未能完全删除：" + failed->error.message() + "。请在文件管理检查残留文件。"; ++deletionRevision;
            }
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
        std::unique_lock<std::mutex> fileLock(fileOperation, std::try_to_lock);
        if (!fileLock.owns_lock()) throw std::runtime_error("文件操作正在进行，请稍后重试");
        int expected = -1;
        if (!archiveProgress.compare_exchange_strong(expected, 0)) throw std::runtime_error("已有解压任务正在进行");
        struct Reset { std::atomic<int>& p; ~Reset() { p = -1; } } reset{archiveProgress};
        cancelArchive = false;
        auto source = checked(j.at("path"));
        ensureComplete(source);
        auto destination = checked(j.at("output"));
        if (fs::exists(destination)) throw std::runtime_error("目标目录已存在，请使用新的目录名称");
        auto first = btmobile::archiveFirstVolume(source, [this](fs::path const& p){
            checked(fs::relative(p, root).generic_string()); ensureComplete(p);
        });
        btmobile::extractArchive(first, destination, j.value("password", ""), archiveProgress, cancelArchive);
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
#ifdef BTMOBILE_OHOS
            network = btmobile_ohos::snapshot(); networkIdentity = network.identity;
#endif
            evaluateNetworkAccess();
            lt::settings_pack settings = settingsPack();
            settings.set_str(lt::settings_pack::user_agent, "Htorrent/1.0.3");
            settings.set_str(lt::settings_pack::peer_fingerprint, "-HT1030-");
            // 6882 (or the user's port) is a preference, not a restriction.
            // Preserve libtorrent's port retries, OS fallback, IPv4/IPv6 peer
            // discovery, outgoing ephemeral ports and NAT mapping negotiation.
            settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::status | lt::alert_category::tracker | lt::alert_category::dht | lt::alert_category::storage)));
            settings.set_str(lt::settings_pack::dht_bootstrap_nodes, "router.bittorrent.com:6881,router.utorrent.com:6881,dht.transmissionbt.com:6881");
#ifdef BTMOBILE_OHOS
            nextNetworkRetry = std::chrono::steady_clock::now() + 30s;
            diagnosticLog("NetworkKit init: code=" + std::to_string(network.code) + " interfaces=" + std::to_string(network.interfaces.size()) + " routes=" + std::to_string(network.routes.size()));
#endif
            session = std::make_unique<lt::session>(settings);
            if (networkBlocked) session->pause();
            // All peer addresses share the global limit, including LAN peers.
            lt::ip_filter classes;
            auto globalClass = 1u << static_cast<unsigned>(lt::session::global_peer_class_id);
            classes.add_rule(lt::make_address("0.0.0.0"),lt::make_address("255.255.255.255"),globalClass);
            classes.add_rule(lt::make_address("::"),lt::make_address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),globalClass);
            session->set_peer_class_filter(classes);
            bool havePauseSettings = false;
            try {
                std::ifstream saved(root / ".state" / "completions.json");
                if (saved) { json data; saved >> data; completionSeen = data.at("seen").get<std::set<std::string>>(); completionPending = data.at("pending"); if (!completionPending.is_object()) completionPending = json::object(); }
            } catch (...) { completionPending = json::object(); diagnosticLog("completion state unavailable"); }
            if (!networkSettings.at("completionNotifications").get<bool>()) completionPending = json::object();
            try {
                std::ifstream saved(root / ".state" / "manual-pauses.json");
                if (saved) { json pauses; saved >> pauses; manuallyPaused = pauses.get<std::set<std::string>>(); havePauseSettings = true; }
            } catch (...) { diagnosticLog("invalid pause settings; resume file flags retained"); }
            for (auto const& file : fs::directory_iterator(root / ".state")) {
                if (file.path().extension() != ".resume") continue;
                try {
                    std::ifstream f(file.path(), std::ios::binary); std::vector<char> bytes((std::istreambuf_iterator<char>(f)),{});
                    lt::error_code ec; auto params = lt::read_resume_data(bytes, ec); if (ec) continue;
                    params.save_path = root.string();
                    bool userPaused = bool(params.flags & lt::torrent_flags::paused) && !(params.flags & lt::torrent_flags::auto_managed);
                    appendDefaultTrackers(params);
                    auto h = session->add_torrent(params, ec); if (!ec) {
                        tasks[id(h)] = h; if (!havePauseSettings && userPaused) manuallyPaused.insert(id(h)); applyTaskPolicy(h);
                    }
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
                        checkNetwork();
                        if (tick % 5 == 0) session->post_dht_stats();
                        if (tick % 30 == 0) diagnosticLog("listening=" + std::to_string(session->is_listening()) + " dht_nodes=" + std::to_string(dhtNodes()) + " tracker_replies=" + std::to_string(trackerReplies) + " metadata=" + std::to_string(metadataReceived));
                    } catch (...) { diagnosticLog("core maintenance failed; retry on next tick"); }
                    std::this_thread::sleep_for(1s);
                }
            });
            return {{"ok",true},{"version",LIBTORRENT_VERSION}};
        }
        if (!session) throw std::runtime_error("下载核心尚未启动");
        if (op == "completionEvents" || op == "ackCompletion") {
            std::lock_guard<std::mutex> l(mutex);
            if (op == "ackCompletion") { completionPending.erase(j.at("id").get<std::string>()); persistCompletions(); return {{"ok",true}}; }
            json events = json::array();
            for (auto const& item : completionPending.items()) events.push_back({{"id",item.key()},{"name",item.value()}});
            return {{"events",events}};
        }
        if (op == "trackers") {
            auto h = task(j); json urls = json::array();
            for (auto const& tracker : h.trackers()) urls.push_back(tracker.url);
            return {{"trackers",urls}};
        }
        if (op == "getNetworkSettings") {
            std::lock_guard<std::mutex> l(mutex);
            return {{"settings",networkSettings},{"defaultTrackers",managedTrackers},{"revision",managedRevision}};
        }
        if (op == "setManagedTrackers") {
            // Called only after pinned server-signature verification. Separate from user settings.
            // Do not restart libtorrent, rewrite custom trackers, or modify existing private torrents.
            std::lock_guard<std::mutex> l(mutex);
            if (!j.at("revision").is_number_integer()) throw std::runtime_error("Tracker 配置版本无效");
            auto revision = j.at("revision").get<std::int64_t>();
            if (revision < 1 || revision < managedRevision) throw std::runtime_error("Tracker 配置版本回退");
            auto list = btmobile::validateSettings(btmobile::defaultSettings(), {{"customTrackers",j.at("trackers")}}).at("customTrackers").get<std::vector<std::string>>();
            if (list.size() > 100) throw std::runtime_error("默认 Tracker 数量超限");
            if (revision == managedRevision && list != managedTrackers) throw std::runtime_error("同版本 Tracker 配置不一致");
            managedTrackers = std::move(list); managedRevision = revision;
            return {{"ok",true},{"revision",managedRevision}};
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
                if (!networkSettings.at("completionNotifications").get<bool>()) {
                    completionPending = json::object(); persistCompletions();
                }
#ifdef BTMOBILE_OHOS
                network = btmobile_ohos::snapshot();
#endif
                evaluateNetworkAccess(); applyNetworkAccess();
                for (auto const& item : tasks) applyTaskPolicy(item.second);
            }
            return {{"ok",true},{"port",btListenPort},{"settings",networkSettings}};
        }
        if (op == "add" || op == "validateAdd") {
            lt::error_code ec; std::string uri = j.at("uri"); lt::add_torrent_params p;
            if (uri.rfind("magnet:?",0) == 0) p = lt::parse_magnet_uri(uri,ec);
            else p = lt::load_torrent_file(checked(uri).string());
            if (ec) throw std::runtime_error("磁力链接或种子文件无效");
            p.save_path = root.string(); p.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
            std::lock_guard<std::mutex> l(mutex);
            // Match either v1 or v2 for hybrid torrents; re-imports must not consume a daily use.
            const auto hashes = p.ti ? p.ti->info_hashes() : p.info_hashes;
            for (auto const& item : tasks) {
                auto existing = item.second.info_hashes();
                if ((hashes.has_v1() && existing.has_v1() && hashes.v1 == existing.v1) ||
                    (hashes.has_v2() && existing.has_v2() && hashes.v2 == existing.v2)) return {{"id",item.first},{"duplicate",true}};
            }
            if (op == "validateAdd") return {{"ok",true},{"duplicate",false}};
            if (!pendingDeletes.empty()) throw std::runtime_error("正在删除下载数据，请稍后再添加任务");
            if (managed()) p.flags |= lt::torrent_flags::auto_managed | lt::torrent_flags::paused;
            appendDefaultTrackers(p);
            auto h = session->add_torrent(p,ec);
            if (ec) throw std::runtime_error(ec.message());
            tasks[id(h)] = h; h.save_resume_data(lt::torrent_handle::save_info_dict);
            return {{"id",id(h)},{"duplicate",false}};
        }
        if (op == "tasks") {
            json list = json::array(); std::lock_guard<std::mutex> l(mutex);
            saveAlerts(); // Queue completion before the UI releases background transfer.
            for (auto const& item: tasks) {
                auto s = item.second.status(); bool paused = bool(s.flags & lt::torrent_flags::paused);
                bool manual = manuallyPaused.count(item.first) != 0;
                bool checking = s.state == lt::torrent_status::checking_files || s.state == lt::torrent_status::checking_resume_data;
                double progress = s.total_wanted > 0 ? std::clamp(double(s.total_wanted_done) / double(s.total_wanted),0.0,1.0) : s.has_metadata && s.is_finished ? 1.0 : 0.0;
                std::string state = s.errc ? "任务错误" : manual ? "已暂停" : networkBlocked ? "等待允许的网络" : paused ? "等待队列" : checking ? "校验文件中" : !s.has_metadata ? "获取元数据" : s.is_finished ? "做种中" : "下载中";
                if (!manual && s.is_finished && !networkSettings.at("seedEnabled").get<bool>()) state = "已完成（做种已关闭）";
                list.push_back({{"id",item.first},{"name",s.name},{"progress",progress},{"done",s.total_wanted_done},{"total",s.total_wanted},
                    {"checking",checking},{"checkProgress",s.progress},{"download",s.download_payload_rate},{"upload",s.upload_payload_rate},
                    {"peers",s.num_peers},{"paused",manual},{"active",!paused && !networkBlocked},{"state",state},{"error",s.errc ? s.errc.message() : ""},
                    {"complete",s.has_metadata && s.is_finished && !checking},{"added",s.added_time},{"downloaded",s.all_time_download},{"uploaded",s.all_time_upload},
                    {"seeds",s.num_seeds},{"swarmSeeds",s.num_complete},{"swarmPeers",s.num_incomplete}});
            }
            return {{"items",list},{"network",diagnostics()},{"deletionMessage",deletionMessage},{"deletionRevision",deletionRevision}};
        }
        if (op == "refreshTask") {
            std::lock_guard<std::mutex> lock(mutex);
            auto h=tasks.at(j.at("id").get<std::string>());
            if (!networkBlocked && !manuallyPaused.count(id(h))) { h.force_reannounce(); h.force_dht_announce(); }
            return {{"ok",true}};
        }
        if (op == "pause" || op == "resume") {
            auto h = task(j); std::lock_guard<std::mutex> lock(mutex);
            auto previous = manuallyPaused;
            if (op == "pause") manuallyPaused.insert(id(h)); else manuallyPaused.erase(id(h));
            try { persistPauses(); } catch (...) { manuallyPaused = previous; throw; }
            applyTaskPolicy(h);
            h.save_resume_data(lt::torrent_handle::save_info_dict); return {{"ok",true}};
        }
        if (op == "remove") {
            auto h=task(j); auto key=id(h);
            bool deleteData = j.value("deleteData", false);
            std::unique_lock<std::mutex> fileLock(fileOperation, std::try_to_lock);
            if (!fileLock.owns_lock()) throw std::runtime_error("文件操作正在进行，暂不能移除任务");
            std::lock_guard<std::mutex> l(mutex);
            if (deleteData) {
                auto info = h.torrent_file(); std::set<fs::path> owned;
                if (info) for (auto i : info->layout().file_range()) owned.insert(fs::weakly_canonical(root / info->layout().file_path(i)));
                for (auto const& other : tasks) if (other.first != key) {
                    auto otherInfo = other.second.torrent_file(); if (!otherInfo) continue;
                    for (auto i : otherInfo->layout().file_range()) if (owned.count(fs::weakly_canonical(root / otherInfo->layout().file_path(i))))
                        throw std::runtime_error("这些文件仍被其他任务共用，请选择仅移除任务以免影响其他下载");
                }
            }
            for(auto it=streams.begin();it!=streams.end();) {
                if(it->second->handle==h){restorePriorities(it->second);it=streams.erase(it);}else ++it;
            }
            auto previous = manuallyPaused; manuallyPaused.erase(key);
            try { persistPauses(); } catch (...) { manuallyPaused = previous; throw; }
            tasks.erase(key);
            completionArmed.erase(key); completionSeen.erase(key); completionPending.erase(key);
            persistCompletions();
            if (deleteData) pendingDeletes.insert(key);
            // libtorrent stops I/O before deleting only files owned by this torrent.
            session->remove_torrent(h, deleteData ? lt::session::delete_files : lt::remove_flags_t{});
            fs::remove(root/".state"/(key+".resume"));
            fs::remove(root/".state"/(key+".resume.tmp"));
            return {{"ok",true},{"deletingData",deleteData}};
        }
        if (op == "deleteFile") {
            std::unique_lock<std::mutex> fileLock(fileOperation, std::try_to_lock);
            if (!fileLock.owns_lock()) throw std::runtime_error("压缩或解压正在进行，请完成或取消后再删除文件");
            auto source = checked(j.at("path"));
            if (!fs::exists(source)) throw std::runtime_error("文件已不存在，请刷新列表");
            if (fs::is_symlink(root / j.at("path").get<std::string>())) throw std::runtime_error("不支持删除符号链接");
            std::lock_guard<std::mutex> lock(mutex);
            if (!pendingDeletes.empty()) throw std::runtime_error("正在清理任务数据，请稍后再删除文件");
            for (auto const& task : tasks) {
                auto info = task.second.torrent_file(); if (!info) continue;
                for (auto i : info->layout().file_range()) {
                    auto path = fs::weakly_canonical(root / info->layout().file_path(i));
                    auto relative = path.lexically_relative(source);
                    if (path == source || (!relative.empty() && !relative.is_absolute() && *relative.begin() != ".."))
                        throw std::runtime_error("此文件仍属于下载任务，请在任务详情选择“移除任务并删除数据”，或先仅移除任务");
                }
            }
            auto removed = fs::remove_all(source);
            return {{"ok",true},{"removed",removed}};
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
            std::unique_lock<std::mutex> fileLock(fileOperation, std::try_to_lock);
            if (!fileLock.owns_lock()) throw std::runtime_error("文件操作正在进行，请稍后重试");
            Utf8Locale utf8;
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
            // Names supplied by ArkTS are UTF-8, not the process C locale.
            if(archive_write_open_filename(writer,output.c_str())!=ARCHIVE_OK)throw std::runtime_error("无法创建 ZIP 文件");
            for(auto const& p:inputs) {
                auto entry=archive_entry_new();
                std::string name=p.lexically_relative(source.parent_path()).generic_string();
                archive_entry_set_pathname_utf8(entry,name.c_str());archive_entry_set_size(entry,fs::file_size(p));
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
