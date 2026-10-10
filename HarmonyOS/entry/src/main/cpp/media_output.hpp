#pragma once
#include "media_engine.hpp"
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <native_window/external_window.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

namespace btmmedia {
class HarmonyOutput final: public Output {
    uint64_t surfaceId;
    OHNativeWindow* window=nullptr;
    EGLDisplay display=EGL_NO_DISPLAY;
    EGLContext context=EGL_NO_CONTEXT;
    EGLSurface surface=EGL_NO_SURFACE;
    GLuint program=0,textures[3]{};
    SwsContext* scaler=nullptr;
    Frame converted{av_frame_alloc()};
    OH_AudioRenderer* renderer=nullptr;
    std::function<void(void*,int)> fill;
    std::function<void()> interrupt;
    static GLuint shader(GLenum type,const char* source) {
        GLuint value=glCreateShader(type);glShaderSource(value,1,&source,nullptr);glCompileShader(value);
        GLint ok=0;glGetShaderiv(value,GL_COMPILE_STATUS,&ok);
        if(!ok){glDeleteShader(value);throw std::runtime_error("视频绘制程序编译失败");}return value;
    }
public:
    explicit HarmonyOutput(uint64_t id):surfaceId(id){}
    void initVideo() override {
        if(OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId,&window)!=0||!window)throw std::runtime_error("无法连接视频画面");
        display=eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if(display==EGL_NO_DISPLAY||!eglInitialize(display,nullptr,nullptr))throw std::runtime_error("无法启动图形显示");
        const EGLint attributes[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
        EGLConfig config;EGLint count=0;
        if(!eglChooseConfig(display,attributes,&config,1,&count)||!count)throw std::runtime_error("找不到视频图形配置");
        const EGLint ctx[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};
        context=eglCreateContext(display,config,EGL_NO_CONTEXT,ctx);
        surface=eglCreateWindowSurface(display,config,reinterpret_cast<EGLNativeWindowType>(window),nullptr);
        if(context==EGL_NO_CONTEXT||surface==EGL_NO_SURFACE||!eglMakeCurrent(display,surface,surface,context))throw std::runtime_error("无法建立视频显示窗口");
        const char* vs="attribute vec2 p; attribute vec2 t; varying vec2 uv; void main(){gl_Position=vec4(p,0.0,1.0);uv=t;}";
        const char* fs="precision mediump float; varying vec2 uv; uniform sampler2D ytex; uniform sampler2D utex; uniform sampler2D vtex; uniform vec3 scale; uniform mat3 matrix; uniform vec3 offset; void main(){vec3 yuv=vec3(texture2D(ytex,vec2(uv.x*scale.x,uv.y)).r,texture2D(utex,vec2(uv.x*scale.y,uv.y)).r,texture2D(vtex,vec2(uv.x*scale.z,uv.y)).r);gl_FragColor=vec4(matrix*(yuv-offset),1.0);}";
        GLuint vertex=shader(GL_VERTEX_SHADER,vs),fragment=shader(GL_FRAGMENT_SHADER,fs);
        program=glCreateProgram();glAttachShader(program,vertex);glAttachShader(program,fragment);glBindAttribLocation(program,0,"p");glBindAttribLocation(program,1,"t");glLinkProgram(program);
        glDeleteShader(vertex);glDeleteShader(fragment);GLint ok=0;glGetProgramiv(program,GL_LINK_STATUS,&ok);if(!ok)throw std::runtime_error("视频绘制程序连接失败");
        glGenTextures(3,textures);
        for(int i=0;i<3;++i){glBindTexture(GL_TEXTURE_2D,textures[i]);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);}
        eglSwapInterval(display,1);
    }
    void draw(AVFrame* original) override {
        AVFrame* frame=original;
        if(frame->format!=AV_PIX_FMT_YUV420P&&frame->format!=AV_PIX_FMT_YUVJ420P) {
            if(!converted)throw std::bad_alloc();
            if(converted->width!=frame->width||converted->height!=frame->height){av_frame_unref(converted.get());converted->format=AV_PIX_FMT_YUV420P;converted->width=frame->width;converted->height=frame->height;requireFF(av_frame_get_buffer(converted.get(),32),"无法分配视频显示内存");}
            requireFF(av_frame_make_writable(converted.get()),"视频显示内存不可写");
            scaler=sws_getCachedContext(scaler,frame->width,frame->height,static_cast<AVPixelFormat>(frame->format),frame->width,frame->height,AV_PIX_FMT_YUV420P,SWS_FAST_BILINEAR,nullptr,nullptr,nullptr);
            if(!scaler)throw std::runtime_error("不支持的视频色彩格式");
            requireFF(sws_scale(scaler,frame->data,frame->linesize,0,frame->height,converted->data,converted->linesize),"视频色彩转换失败");frame=converted.get();
        }
        EGLint width=0,height=0;eglQuerySurface(display,surface,EGL_WIDTH,&width);eglQuerySurface(display,surface,EGL_HEIGHT,&height);
        if(width<=0||height<=0)return;
        glViewport(0,0,width,height);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
        double sar=original->sample_aspect_ratio.num>0?av_q2d(original->sample_aspect_ratio):1;
        double ratio=double(frame->width)*sar/frame->height;
        float sx=1,sy=1;if(double(width)/height>ratio)sx=ratio*height/width;else sy=width/ratio/height;
        GLfloat vertices[]={-sx,-sy,0,1,sx,-sy,1,1,-sx,sy,0,0,sx,sy,1,0};
        glUseProgram(program);glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,4*sizeof(GLfloat),vertices);glVertexAttribPointer(1,2,GL_FLOAT,GL_FALSE,4*sizeof(GLfloat),vertices+2);glEnableVertexAttribArray(0);glEnableVertexAttribArray(1);
        glPixelStorei(GL_UNPACK_ALIGNMENT,1);float scales[3];
        for(int i=0;i<3;++i){int h=i?(frame->height+1)/2:frame->height,w=i?(frame->width+1)/2:frame->width;glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,textures[i]);glTexImage2D(GL_TEXTURE_2D,0,GL_LUMINANCE,frame->linesize[i],h,0,GL_LUMINANCE,GL_UNSIGNED_BYTE,frame->data[i]);scales[i]=float(w)/frame->linesize[i];}
        glUniform1i(glGetUniformLocation(program,"ytex"),0);glUniform1i(glGetUniformLocation(program,"utex"),1);glUniform1i(glGetUniformLocation(program,"vtex"),2);glUniform3fv(glGetUniformLocation(program,"scale"),1,scales);
        bool full=original->color_range==AVCOL_RANGE_JPEG;
        bool bt709=original->colorspace==AVCOL_SPC_BT709||original->height>=720;
        float y=full?1:1.1643836f;
        GLfloat matrix[]={y,y,y,0,bt709?-0.213249f:-0.391762f,bt709?2.112402f:2.017232f,bt709?1.792741f:1.596027f,bt709?-0.532909f:-0.812968f,0};
        if(full){matrix[4]*=224.0f/255;matrix[5]*=224.0f/255;matrix[6]*=224.0f/255;matrix[7]*=224.0f/255;}
        glUniformMatrix3fv(glGetUniformLocation(program,"matrix"),1,GL_FALSE,matrix);glUniform3f(glGetUniformLocation(program,"offset"),full?0:16.0f/255,128.0f/255,128.0f/255);
        glDrawArrays(GL_TRIANGLE_STRIP,0,4);if(!eglSwapBuffers(display,surface))throw std::runtime_error("视频画面提交失败");
    }
    void closeVideo() override {
        sws_freeContext(scaler);scaler=nullptr;
        if(display!=EGL_NO_DISPLAY){if(context!=EGL_NO_CONTEXT){glDeleteTextures(3,textures);if(program)glDeleteProgram(program);}eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);if(surface!=EGL_NO_SURFACE)eglDestroySurface(display,surface);if(context!=EGL_NO_CONTEXT)eglDestroyContext(display,context);eglTerminate(display);}
        if(window)OH_NativeWindow_DestroyNativeWindow(window);window=nullptr;display=EGL_NO_DISPLAY;context=EGL_NO_CONTEXT;surface=EGL_NO_SURFACE;
    }
    void startAudio(std::function<void(void*,int)> callback,std::function<void()> interrupted) override {
        fill=std::move(callback);interrupt=std::move(interrupted);
        OH_AudioStreamBuilder* builder=nullptr;
        auto check=[](OH_AudioStream_Result r){if(r!=AUDIOSTREAM_SUCCESS)throw std::runtime_error("无法启动系统音频输出");};
        check(OH_AudioStreamBuilder_Create(&builder,AUDIOSTREAM_TYPE_RENDERER));
        try{
            check(OH_AudioStreamBuilder_SetSamplingRate(builder,48000));check(OH_AudioStreamBuilder_SetChannelCount(builder,2));
            check(OH_AudioStreamBuilder_SetSampleFormat(builder,AUDIOSTREAM_SAMPLE_S16LE));check(OH_AudioStreamBuilder_SetEncodingType(builder,AUDIOSTREAM_ENCODING_TYPE_RAW));
            check(OH_AudioStreamBuilder_SetRendererInfo(builder,AUDIOSTREAM_USAGE_MOVIE));
            OH_AudioRenderer_Callbacks callbacks{};
            callbacks.OH_AudioRenderer_OnWriteData=[](OH_AudioRenderer*,void* user,void* data,int32_t bytes){static_cast<HarmonyOutput*>(user)->fill(data,bytes);return 0;};
            callbacks.OH_AudioRenderer_OnInterruptEvent=[](OH_AudioRenderer*,void* user,OH_AudioInterrupt_ForceType,OH_AudioInterrupt_Hint hint){if(hint==AUDIOSTREAM_INTERRUPT_HINT_PAUSE||hint==AUDIOSTREAM_INTERRUPT_HINT_STOP)static_cast<HarmonyOutput*>(user)->interrupt();return 0;};
            callbacks.OH_AudioRenderer_OnError=[](OH_AudioRenderer*,void* user,OH_AudioStream_Result){static_cast<HarmonyOutput*>(user)->interrupt();return 0;};
            check(OH_AudioStreamBuilder_SetRendererCallback(builder,callbacks,this));check(OH_AudioStreamBuilder_GenerateRenderer(builder,&renderer));check(OH_AudioRenderer_Start(renderer));
        }catch(...){OH_AudioStreamBuilder_Destroy(builder);throw;}
        OH_AudioStreamBuilder_Destroy(builder);
    }
    void stopAudio() override {if(renderer){OH_AudioRenderer_Stop(renderer);OH_AudioRenderer_Release(renderer);renderer=nullptr;}}
};
}
