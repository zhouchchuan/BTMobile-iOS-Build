#define BTM_MEDIA_PBUFFER_TEST 1
#include "../entry/src/main/cpp/media_output.hpp"
#include <iostream>
using namespace btmmedia;
int main(){try{
    HarmonyOutput sink(0);sink.initVideo();
    for(auto format:{AV_PIX_FMT_YUV420P,AV_PIX_FMT_YUV420P10LE}){
        Frame f(av_frame_alloc());f->format=format;f->width=318;f->height=178;f->sample_aspect_ratio={1,1};f->color_range=AVCOL_RANGE_MPEG;
        requireFF(av_frame_get_buffer(f.get(),32),"allocate");
        for(int i=0;i<3;++i){int h=i?89:178,w=i?159:318;for(int y=0;y<h;++y){auto row=f->data[i]+y*f->linesize[i];if(format==AV_PIX_FMT_YUV420P)std::fill(row,row+w,i?128:235);else std::fill(reinterpret_cast<uint16_t*>(row),reinterpret_cast<uint16_t*>(row)+w,i?512:940);}}
        sink.draw(f.get());unsigned char center[4]{},bar[4]{};
        glReadPixels(160,120,1,1,GL_RGBA,GL_UNSIGNED_BYTE,center);glReadPixels(160,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,bar);
        if(glGetError()!=GL_NO_ERROR||center[0]<240||center[1]<240||center[2]<240||bar[0]>5)throw std::runtime_error("render pixel/letterbox validation failed");
        std::cout<<"PASS real GLES3 pixels, padded stride, letterbox, format="<<format<<std::endl;
    }
    sink.closeVideo();return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}}
