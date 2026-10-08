#define BT_MOBILE_HOST_TEST
#include "../entry/src/main/cpp/bridge.cpp"
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <cassert>

// A locally generated payload and loopback-only swarm; no third-party media.
int main(int argc,char** argv) {
    if(argc!=2) return 2;
    fs::path scratch=fs::absolute(argv[1]);fs::create_directories(scratch/"seed");fs::create_directories(scratch/"download");
    std::string payload(1024*1024,'x');
    for(size_t i=0;i<payload.size();++i)payload[i]=char((i*37+17)%251);
    {std::ofstream f(scratch/"seed"/"fixture.bin",std::ios::binary);f.write(payload.data(),payload.size());}
    lt::file_storage storage;storage.add_file("fixture.bin",payload.size());
    lt::create_torrent creator(storage,16384,lt::create_torrent::v1_only);
    lt::set_piece_hashes(creator,(scratch/"seed").string());
    auto encoded=creator.generate_buf();
    fs::path torrent=scratch/"download"/"fixture.torrent";
    {std::ofstream f(torrent,std::ios::binary);f.write(encoded.data(),encoded.size());}
    lt::settings_pack options;
    options.set_str(lt::settings_pack::listen_interfaces,"127.0.0.1:0");
    options.set_bool(lt::settings_pack::enable_dht,false);options.set_bool(lt::settings_pack::enable_lsd,false);
    options.set_bool(lt::settings_pack::enable_upnp,false);options.set_bool(lt::settings_pack::enable_natpmp,false);
    lt::session seeder(options);
    lt::add_torrent_params params;params.ti=std::make_shared<lt::torrent_info>(torrent.string());params.save_path=(scratch/"seed").string();
    params.flags=lt::torrent_flags::seed_mode;auto seed=seeder.add_torrent(params);
    for(int i=0;i<100 && seeder.listen_port()==0;++i)std::this_thread::sleep_for(100ms);
    assert(seeder.listen_port()!=0);
    Core core;
    auto init=core.call({{"op","init"},{"root",(scratch/"download").string()}});
    assert(init.at("version").get<std::string>().find("2.1") == 0);
    std::string magnet=lt::make_magnet_uri(*params.ti)+"&x.pe=127.0.0.1:"+std::to_string(seeder.listen_port());
    auto added=core.call({{"op","add"},{"uri",magnet}}); std::string hash=added.at("id");
    bool complete=false;
    for(int i=0;i<300;++i) {
        auto status=core.call({{"op","tasks"}});
        if(status["items"][0]["progress"].get<float>()>=1.0f){complete=true;break;}
        std::this_thread::sleep_for(100ms);
    }
    assert(complete);
    std::ifstream downloaded(scratch/"download"/"fixture.bin",std::ios::binary);
    std::string actual((std::istreambuf_iterator<char>(downloaded)),{}); assert(actual==payload);
    core.call({{"op","pause"},{"id",hash}}); std::this_thread::sleep_for(250ms);
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
    std::cout << "PASS: real magnet metadata, loopback download, verified bytes, pause, HTTP seek range, ZIP roundtrip\n";
}
