#include "../entry/src/main/cpp/media_probe.hpp"
#include <fcntl.h>
#include <iostream>
using namespace btmmedia;
int main(int argc,char**argv){try{if(argc<2)return 2;int fd=open(argv[1],O_RDONLY);auto result=MediaProbe().run(fd,"");close(fd);
    if(result["videoCodec"]!="av1"||result["tracks"].size()!=3)throw std::runtime_error("codec/track inventory mismatch");
    bool title=false;for(auto& t:result["tracks"])if(t["track_type"]==2&&t["language"]=="chi"&&t["track_name"]=="Simplified Chinese")title=true;
    if(!title)throw std::runtime_error("lost subtitle language/title");std::cout<<"PASS real container codec/language/title probe"<<std::endl;return 0;
}catch(std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
