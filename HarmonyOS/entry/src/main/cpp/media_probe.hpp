#pragma once
#include "media_engine.hpp"
namespace btmmedia {
// Read container metadata without writing/remuxing the file. No user path or
// track title is written to logs. Probe does not acquire the live-player mutex.
class MediaProbe {
    int fd=-1; int64_t offset=0,size=0,deadline=0;
    static int read(void* o,uint8_t* b,int n){auto& p=*static_cast<MediaProbe*>(o);auto r=pread(p.fd,b,n,p.offset);if(r<0)return AVERROR(errno);p.offset+=r;return r?int(r):AVERROR_EOF;}
    static int64_t seek(void* o,int64_t n,int mode){auto& p=*static_cast<MediaProbe*>(o);if(mode==AVSEEK_SIZE)return p.size;mode&=~AVSEEK_FORCE;auto next=mode==SEEK_SET?n:mode==SEEK_CUR?p.offset+n:mode==SEEK_END?p.size+n:-1;if(next<0||next>p.size)return AVERROR(EINVAL);return p.offset=next;}
    static int interrupt(void* o){return monotonicMs()>static_cast<MediaProbe*>(o)->deadline;}
public:
    Json run(int input,const std::string& url){
        AVFormatContext* f=avformat_alloc_context();AVIOContext* io=nullptr;Json result;
        if(!f)throw std::bad_alloc();
        try{
            deadline=monotonicMs()+8000;f->interrupt_callback={interrupt,this};
            if(input>=0){fd=dup(input);struct stat st{};if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode))throw std::runtime_error("视频文件不可读");size=st.st_size;
                auto b=static_cast<uint8_t*>(av_malloc(65536));if(!b)throw std::bad_alloc();io=avio_alloc_context(b,65536,0,this,read,nullptr,seek);if(!io){av_free(b);throw std::bad_alloc();}f->pb=io;f->flags|=AVFMT_FLAG_CUSTOM_IO;
            }else if(!std::regex_match(url,std::regex(R"(http://127\.0\.0\.1:[0-9]{1,5}/stream/[A-Za-z0-9/_-]+)")))throw std::runtime_error("仅接受本地视频");
            AVDictionary* options=nullptr;av_dict_set(&options,"protocol_whitelist",fd>=0?"file":"http,tcp",0);av_dict_set(&options,"probesize","1048576",0);av_dict_set(&options,"analyzeduration","1000000",0);
            int r=avformat_open_input(&f,fd>=0?nullptr:url.c_str(),nullptr,&options);av_dict_free(&options);requireFF(r,"读取容器失败");
            if(!f->nb_streams)requireFF(avformat_find_stream_info(f,nullptr),"读取轨道失败");
            result={{"tracks",Json::array()},{"videoCodec",""}};
            for(unsigned i=0;i<f->nb_streams;++i){auto s=f->streams[i];auto c=s->codecpar;
                if(c->codec_type==AVMEDIA_TYPE_VIDEO&&result["videoCodec"]==""){result["videoCodec"]=avcodec_get_name(c->codec_id);result["width"]=c->width;result["height"]=c->height;}
                if(c->codec_type!=AVMEDIA_TYPE_AUDIO&&c->codec_type!=AVMEDIA_TYPE_SUBTITLE)continue;
                auto language=av_dict_get(s->metadata,"language",nullptr,0),title=av_dict_get(s->metadata,"title",nullptr,0);
                result["tracks"].push_back({{"track_index",i},{"track_type",c->codec_type==AVMEDIA_TYPE_AUDIO?0:2},{"language",language?language->value:""},{"track_name",title?title->value:""},{"codec_mime",avcodec_get_name(c->codec_id)}});
            }
        }catch(...){avformat_close_input(&f);if(io){av_freep(&io->buffer);avio_context_free(&io);}if(fd>=0)::close(fd);throw;}
        avformat_close_input(&f);if(io){av_freep(&io->buffer);avio_context_free(&io);}if(fd>=0)::close(fd);return result;
    }
};
}
