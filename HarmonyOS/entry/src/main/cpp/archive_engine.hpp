#pragma once
#include "range.hpp"
#include <bit7z/bit7zlibrary.hpp>
#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitnestedarchivereader.hpp>
#include <bit7z/bitexception.hpp>
#include <bit7z/biterror.hpp>
#include <atomic>
#include <functional>
#include <regex>
#include <set>
#include <limits>
#include <sys/stat.h>

namespace btmobile {
namespace afs = std::filesystem;
inline std::string archiveLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c){ return std::tolower(c); }); return s;
}
// Select any volume: use the first member, validate the entire available family,
// and let 7-Zip validate the final volume/CRC. No concatenation into a giant file.
inline afs::path archiveFirstVolume(afs::path source, std::function<void(afs::path const&)> const& check) {
    std::string name = source.filename().string(); std::smatch m;
    std::string prefix, suffix; int digits = 0, start = 1;
    if (std::regex_match(name, m, std::regex("(.+\\.(?:7z|zip))\\.([0-9]{3,})", std::regex::icase))) {
        prefix=m[1].str()+"."; digits=int(m[2].length());
    } else if (std::regex_match(name, m, std::regex("(.+\\.part)([0-9]+)(\\.rar)", std::regex::icase))) {
        prefix=m[1]; digits=int(m[2].length()); suffix=m[3];
    } else if (std::regex_match(name, m, std::regex("(.+)\\.([zr])([0-9]{2,})", std::regex::icase))) {
        source=source.parent_path()/(m[1].str()+(archiveLower(m[2])=="z"?".zip":".rar"));
    }
    if (digits) {
        std::string one(digits-1,'0'); one+='1'; source=source.parent_path()/(prefix+one+suffix);
    }
    if (!afs::is_regular_file(afs::symlink_status(source))) throw std::runtime_error("缺少首个分卷，请将全部分卷放在同一文件夹");
    check(source);
    if (!digits) {
        auto ext=archiveLower(source.extension().string());
        if (ext==".zip" || ext==".rar") { prefix=source.stem().string()+(ext==".zip"?".z":".r"); digits=2; start=ext==".zip"?1:0; }
    }
    std::set<int> parts;
    if (digits) for (auto const& entry: afs::directory_iterator(source.parent_path())) {
        auto n=entry.path().filename().string();
        if (n.size() < prefix.size()+suffix.size()+size_t(digits) || n.compare(0,prefix.size(),prefix)!=0 ||
            (!suffix.empty() && n.substr(n.size()-suffix.size())!=suffix)) continue;
        auto number=n.substr(prefix.size(),n.size()-prefix.size()-suffix.size());
        if(number.empty() || number.find_first_not_of("0123456789")!=number.npos)continue;
        if(number.size()>6)throw std::runtime_error("分卷编号超出支持范围");
        if(!afs::is_regular_file(entry.symlink_status()))throw std::runtime_error("分卷不是普通文件，已停止解压");
        check(entry.path()); parts.insert(std::stoi(number));
    }
    if(!parts.empty()) for(int i=start;i<=*parts.rbegin();++i) if(!parts.count(i))
        throw std::runtime_error("分卷缺失：第 "+std::to_string(i)+" 卷，请将全部分卷放在同一文件夹");
    return source;
}

template<class Reader> inline void extractChecked(Reader& reader, afs::path const& destination,
    std::atomic<int>& progress, std::atomic<bool>& cancel, bool& encrypted) {
    using namespace bit7z;
    if(reader.itemsCount()>1000000)throw std::runtime_error("压缩包文件数量过多");
    std::set<std::string> paths; uint64_t total=0;
    for(auto const& item:reader.items()) {
        if(cancel)throw std::runtime_error("解压已取消");
        auto name=item.path(); std::replace(name.begin(),name.end(),'\\','/');
        auto normalized=afs::path(name).lexically_normal().generic_string();
        if(!safeArchivePath(name) || (normalized=="." && !item.isDir()) || item.isSymLink() || !item.itemProperty(BitProperty::HardLink).isEmpty())
            throw std::runtime_error("压缩包含有不安全路径或链接，已停止解压");
        auto mode=item.itemProperty(BitProperty::PosixAttrib);
        if(mode.isUInt32()) { auto kind=mode.getUInt32()&S_IFMT; if(kind && kind!=S_IFDIR && kind!=S_IFREG)throw std::runtime_error("压缩包包含特殊文件，已停止解压"); }
        if(!paths.insert(normalized).second)throw std::runtime_error("压缩包含有重复文件名，已停止以免覆盖文件");
        encrypted=encrypted||item.isEncrypted();
        if(!item.isDir()) {
            if(item.size()>std::numeric_limits<uint64_t>::max()-total)throw std::runtime_error("压缩包大小无效");
            total+=item.size();
        }
    }
    if(encrypted && !reader.isPasswordDefined())throw std::runtime_error("此压缩包已加密，请输入密码后重试");
    if(total>afs::space(destination.parent_path()).available)throw std::runtime_error("剩余空间不足，无法解压");
    reader.setOverwriteMode(OverwriteMode::None);
    reader.setTotalCallback([&](uint64_t value){total=value;});
    reader.setProgressCallback([&](uint64_t done){ progress=total?int(std::min(99.0L,100.0L*done/total)):0; return !cancel.load(); });
    // The caller has checked nonexistence; create_directory fails if another actor
    // occupied it. Library additionally rejects traversal and existing outputs.
    if(!afs::create_directory(destination))throw std::runtime_error("目标目录已存在，请使用新的目录名称");
    reader.extractTo(destination.string());
    progress=100;
}

inline void extractArchive(afs::path const& source, afs::path const& destination, std::string const& password,
    std::atomic<int>& progress, std::atomic<bool>& cancel, std::string const& library="lib7zip.so") {
    using namespace bit7z; bool encrypted=false;
    try {
        auto name=archiveLower(source.filename().string());
        // Auto-detection treats .001 as a Split container and would only join
        // the volumes. Select the inner archive so bit7z uses its seekable
        // multi-volume stream and extracts actual files without a giant copy.
        const BitInFormat* format=&BitFormat::Auto;
        if(std::regex_match(name,std::regex(".+\\.7z\\.001"))) format=&BitFormat::SevenZip;
        else if(std::regex_match(name,std::regex(".+\\.zip\\.001"))) format=&BitFormat::Zip;
        Bit7zLibrary lib(library); BitArchiveReader reader(lib,source.string(),*format,password);
        bool tarball=std::regex_match(name,std::regex(".+\\.(?:tar\\.(?:gz|xz|bz2|zst)|tgz|txz|tbz|tbz2)"));
        if(tarball && reader.detectedFormat()!=BitFormat::Tar) {
            BitNestedArchiveReader nested(lib,reader,BitFormat::Tar,password);
            nested.setMaxMemoryUsage(64*1024*1024);
            extractChecked(nested,destination,progress,cancel,encrypted);
        } else extractChecked(reader,destination,progress,cancel,encrypted);
    } catch(BitException const& e) {
        if(cancel)throw std::runtime_error("解压已取消，未修改原压缩包；可重新解压");
        auto code=e.code();
        if(code==BitFailureSource::WrongPassword)
            throw std::runtime_error(password.empty()?"此压缩包已加密，请输入密码后重试":"密码错误，请重新输入密码");
        if(code==BitFailureSource::UnexpectedEnd || code==BitFailureSource::UnavailableData)
            throw std::runtime_error("压缩包数据不完整或分卷缺失，请检查全部分卷是否齐全");
        if(code==BitFailureSource::CRCError || code==BitFailureSource::DataError)
            throw std::runtime_error(encrypted?"密码不正确或压缩包校验失败，请核对密码和全部分卷":"压缩包校验失败，请检查下载完整性及分卷是否齐全");
        if(code==BitFailureSource::OperationNotSupported)throw std::runtime_error("此压缩包使用了暂不支持的压缩方法");
        if(code==BitFailureSource::InvalidArchive || code==BitFailureSource::FormatDetectionError || code==BitFailureSource::HeadersError)
            throw std::runtime_error("无法打开压缩包，请检查格式、密码和全部分卷；这不一定代表文件损坏");
        if(code==std::errc::no_space_on_device)throw std::runtime_error("存储空间不足，无法完成解压");
        throw std::runtime_error("解压未完成，请检查密码、剩余空间及全部分卷（错误码 "+std::to_string(code.value())+"）");
    }
}
}
