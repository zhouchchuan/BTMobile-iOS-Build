#define BT_MOBILE_HOST_TEST
#include "../entry/src/main/cpp/bridge.cpp"
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <cassert>
#include <iostream>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

// Deliberately occupy both families/protocols: the preferred port must not
// prevent libtorrent from finding an alternate listener and downloading.
struct OccupiedPort {
    std::vector<int> sockets;
    explicit OccupiedPort(int port) {
        for (int family : {AF_INET, AF_INET6}) for (int type : {SOCK_STREAM, SOCK_DGRAM}) {
            int fd = ::socket(family, type, 0); assert(fd >= 0);
            int result;
            if (family == AF_INET6) {
                int only = 1; assert(::setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof(only)) == 0);
                sockaddr_in6 addr{}; addr.sin6_family = AF_INET6; addr.sin6_port = htons(port);
                result = ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
            } else {
                sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_port = htons(port);
                result = ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
            }
            assert(result == 0);
            if (type == SOCK_STREAM) assert(::listen(fd, 1) == 0);
            sockets.push_back(fd);
        }
    }
    ~OccupiedPort() { for (int fd : sockets) ::close(fd); }
};

// A locally generated payload and loopback-only swarm; no third-party media.
int main(int argc,char** argv) {
    if(argc!=2) return 2;
    fs::path scratch=fs::absolute(argv[1]);fs::create_directories(scratch/"seed");fs::create_directories(scratch/"download");
    std::string payload(1024*1024,'x');
    for(size_t i=0;i<payload.size();++i)payload[i]=char((i*37+17)%251);
    {std::ofstream f(scratch/"seed"/"fixture.bin",std::ios::binary);f.write(payload.data(),payload.size());}
    lt::create_file_entry fixture("fixture.bin",payload.size());
    lt::create_torrent creator(std::vector<lt::create_file_entry>{fixture},16384,lt::create_torrent::v1_only);
    lt::set_piece_hashes(creator,(scratch/"seed").string());
    auto encoded=creator.generate_buf();
    fs::path torrent=scratch/"download"/"fixture.torrent";
    {std::ofstream f(torrent,std::ios::binary);f.write(encoded.data(),encoded.size());}
    lt::settings_pack options;
    options.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    options.set_bool(lt::settings_pack::enable_dht,false);options.set_bool(lt::settings_pack::enable_lsd,false);
    options.set_bool(lt::settings_pack::enable_upnp,false);options.set_bool(lt::settings_pack::enable_natpmp,false);
    lt::session seeder(options);
    auto params=lt::load_torrent_file(torrent.string());params.save_path=(scratch/"seed").string();
    params.flags=lt::torrent_flags::seed_mode;auto seed=seeder.add_torrent(params);
    for(int i=0;i<100 && seeder.listen_port()==0;++i)std::this_thread::sleep_for(100ms);
    assert(seeder.listen_port()!=0);
    // A real HTTP tracker response discovers the seed. No x.pe shortcut, no
    // fixed peer injected into the client, and no external payload or swarm.
    httplib::Server tracker;
    std::atomic<int> announces{0};
    tracker.Get("/announce", [&](httplib::Request const&, httplib::Response& res) {
        ++announces; int seedPort = seeder.listen_port();
        std::string peers; peers += char(127); peers += char(0); peers += char(0); peers += char(1);
        peers += char(seedPort >> 8); peers += char(seedPort & 255);
        res.set_content("d8:intervali10e5:peers6:" + peers + "e", "application/x-bittorrent");
    });
    int trackerPort = tracker.bind_to_any_port("127.0.0.1"); assert(trackerPort > 0);
    std::thread trackerThread([&]{tracker.listen_after_bind();});
    struct StopTracker { httplib::Server& tracker; std::thread& thread; ~StopTracker(){tracker.stop();thread.join();} } stopTracker{tracker, trackerThread};
    OccupiedPort occupied(6882);
    Core core;
    auto init=core.call({{"op","init"},{"root",(scratch/"download").string()}});
    assert(init.at("version").get<std::string>().find("2.1") == 0);
    auto defaults = core.call({{"op","getNetworkSettings"}}).at("settings");
    assert(defaults.at("listenPort") == 6882);
    for(auto const& key : {"dht","lsd","natPmp","upnp","utp"}) assert(defaults.at(key) == true);
    // No-op updates and validation must not disturb tasks; stored settings are
    // independent of background preferences and the HTTP playback port.
    core.call({{"op","setNetworkSettings"},{"settings",{{"lsd",false},{"upnp",false},{"natPmp",false},{"dht",false}}}});
    bool rejected = false;
    try { core.call({{"op","setListenPort"},{"port",70000}}); } catch (std::exception const&) { rejected = true; }
    assert(rejected && core.call({{"op","getNetworkSettings"}})["settings"]["listenPort"] == 6882);
    std::string magnet=lt::make_magnet_uri(params)+"&tr=http%3A%2F%2F127.0.0.1%3A"+std::to_string(trackerPort)+"%2Fannounce";
    auto added=core.call({{"op","add"},{"uri",magnet}}); std::string hash=added.at("id");
    bool complete=false;
    for(int i=0;i<300;++i) {
        auto status=core.call({{"op","tasks"}});
        if(status["items"][0]["progress"].get<float>()>=1.0f){complete=true;break;}
        std::this_thread::sleep_for(100ms);
    }
    assert(complete);
    assert(announces > 0);
    auto net = core.call({{"op","tasks"}}).at("network");
    assert(net.at("listening") == true && net.at("configuredPort") == 6882);
    assert(net.at("listenPort").get<int>() > 0 && net.at("listenPort") != 6882);
    std::ifstream downloaded(scratch/"download"/"fixture.bin",std::ios::binary);
    std::string actual((std::istreambuf_iterator<char>(downloaded)),{}); assert(actual==payload);
    auto completed = core.call({{"op","tasks"}})["items"][0];
    assert(completed["done"] == payload.size() && completed["total"] == payload.size());
    core.call({{"op","setNetworkSettings"},{"settings",{{"queueEnabled",true},{"maxSeeds",0},{"maxActive",2},{"downloadLimitKiB",512},{"uploadLimitKiB",256}}}});
    bool queued = false;
    for (int i=0;i<100;++i) {
        auto task = core.call({{"op","tasks"}})["items"][0];
        if (!task["active"].get<bool>() && !task["paused"].get<bool>()) { queued = true; break; }
        std::this_thread::sleep_for(100ms);
    }
    assert(queued); // Queued and manually paused are different states.
    core.call({{"op","pause"},{"id",hash}}); std::this_thread::sleep_for(250ms);
    assert(core.call({{"op","tasks"}})["items"][0]["paused"]==true);
    core.call({{"op","setNetworkSettings"},{"settings",{{"queueEnabled",false},{"seedEnabled",true}}}});
    std::this_thread::sleep_for(250ms);
    assert(core.call({{"op","tasks"}})["items"][0]["paused"]==true);
    auto stream=core.call({{"op","stream"},{"id",hash},{"index",0}});
    std::string url=stream.at("url"); auto slash=url.find('/',7);
    httplib::Client client(url.substr(0,slash)); auto response=client.Get(url.substr(slash),{{"Range","bytes=10-99"}});
    assert(response && response->status==206 && response->body==payload.substr(10,90));
    auto invalid=client.Get(url.substr(slash),{{"Range","bytes=9999999-"}}); assert(invalid && invalid->status==416);
    core.call({{"op","stopStream"}});
    core.call({{"op","compress"},{"path","fixture.bin"},{"output","fixture.zip"}});
    core.call({{"op","extract"},{"path","fixture.zip"},{"output","expanded"}});
    std::ifstream extracted(scratch/"download"/"expanded"/"fixture.bin",std::ios::binary);
    std::string roundtrip((std::istreambuf_iterator<char>(extracted)),{});assert(roundtrip==payload);
    fs::create_directories(scratch/"download"/u8"中文样例");
    { std::ofstream f(scratch/"download"/u8"中文样例"/u8"说明.txt"); f << u8"UTF-8 文本与链接 https://example.org/"; }
    { std::ofstream f(scratch/"download"/u8"中文样例"/u8"图片.jpg",std::ios::binary); f.write(payload.data(),128); }
    core.call({{"op","compress"},{"path",u8"中文样例"},{"output","unicode.zip"}});
    core.call({{"op","extract"},{"path","unicode.zip"},{"output","unicode-output"}});
    assert(fs::file_size(scratch/"download"/"unicode-output"/u8"中文样例"/u8"图片.jpg") == 128);
    std::ifstream text(scratch/"download"/"unicode-output"/u8"中文样例"/u8"说明.txt");
    assert(std::string((std::istreambuf_iterator<char>(text)),{}) == u8"UTF-8 文本与链接 https://example.org/");
    { std::ofstream f(scratch/"download"/"invalid.zip"); f << "not an archive"; }
    bool badArchive = false;
    try { core.call({{"op","extract"},{"path","invalid.zip"},{"output","invalid-output"}}); }
    catch(std::exception const&) { badArchive = true; }
    assert(badArchive && core.call({{"op","archiveProgress"}})["percent"] == -1);
    core.call({{"op","extract"},{"path","unicode.zip"},{"output","retry-output"}});
    assert(fs::exists(scratch/"download"/"retry-output"/u8"中文样例"/u8"说明.txt"));
    for (auto path : {".",".state","../seed","fixture.bin"}) {
        bool blocked = false;
        try { core.call({{"op","deleteFile"},{"path",path}}); } catch(std::exception const&) { blocked = true; }
        assert(blocked);
    }
    core.call({{"op","deleteFile"},{"path","unicode-output"}});
    assert(!fs::exists(scratch/"download"/"unicode-output") && fs::exists(scratch/"download"/"unicode.zip"));
    auto configured = core.call({{"op","setNetworkSettings"},{"settings",{{"utp",false}}}});
    assert(configured["settings"]["utp"] == false && configured["settings"]["listenPort"] == 6882);
    std::ifstream saved(scratch/"download"/".state"/"network.json"); json savedSettings; saved >> savedSettings;
    assert(savedSettings["utp"] == false);
    core.call({{"op","setListenPort"},{"port",49182}});
    assert(core.call({{"op","getNetworkSettings"}})["settings"]["listenPort"] == 49182);
    { std::ifstream changed(scratch/"download"/".state"/"network.json"); changed >> savedSettings; }
    assert(savedSettings["listenPort"] == 49182);
    core.call({{"op","remove"},{"id",hash},{"deleteData",false}});
    assert(fs::exists(scratch/"download"/"fixture.bin"));
    auto readded = core.call({{"op","add"},{"uri","fixture.torrent"}});
    core.call({{"op","remove"},{"id",readded["id"]},{"deleteData",true}});
    for(int i=0;i<100 && fs::exists(scratch/"download"/"fixture.bin");++i) std::this_thread::sleep_for(100ms);
    assert(!fs::exists(scratch/"download"/"fixture.bin") && fs::exists(scratch/"download"/"unicode.zip"));
    std::cout << "PASS: tracker/metadata/bytes with occupied port, queue/manual pause distinction, settings persistence, HTTP seek, UTF-8 ZIP roundtrip, extraction retry, scoped file deletion and both task-removal modes\n";
}
