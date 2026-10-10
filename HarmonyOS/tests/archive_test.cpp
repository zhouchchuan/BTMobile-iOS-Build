#include "../entry/src/main/cpp/archive_engine.hpp"
#include <iostream>
int main(int argc,char** argv) {
    if(argc!=4)return 2;
    std::atomic<int> progress{0}; std::atomic<bool> cancel{false};
    try {
        auto input=btmobile::archiveFirstVolume(argv[1],[](auto const&){});
        btmobile::extractArchive(input,argv[2],argv[3],progress,cancel);
        if(progress!=100)return 3;
        std::cout<<"EXTRACT_OK\n"; return 0;
    } catch(std::exception const& e) { std::cerr<<e.what()<<'\n'; return 1; }
}
