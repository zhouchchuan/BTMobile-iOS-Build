export interface AboutSection { title: string; text: string }
export const ABOUT_SECTIONS: AboutSection[] = [
  { title: '关于 BTmobie', text: '下载、管理、解压与播放，一站完成。\n\nBTmobie 是面向 HarmonyOS 的 BT 下载与本地文件处理工具，支持磁力链接、Torrent 文件及种子下载地址添加任务，提供后台下载与做种、文件管理、压缩包解压、本地媒体播放和边下边播等功能。\n\n我们希望让文件从下载到使用的每一步，都更简单、顺畅。' },
  { title: '开源项目与致谢', text: 'BTmobie 的开发离不开开源社区的贡献。我们向以下项目的作者、贡献者及维护者致以感谢：\n\nlibtorrent：提供 BitTorrent 下载与做种核心。\n\nFFmpeg、dav1d：提供媒体处理与 AV1 兼容解码能力。\n\n7-Zip、bit7z、libarchive：提供压缩文件读取与解压能力。\n\nOpenSSL：提供密码学与安全通信基础能力。\n\nBoost、zlib、XZ/liblzma、nlohmann/json、cpp-httplib：提供底层支持、压缩、数据处理及网络通信能力。\n\niTorrent：感谢上游开源项目及其贡献者。\n\n各开源组件的版权归其原作者及权利人所有，并按各自许可证使用。上述致谢不表示相关项目与 BTmobie 存在官方合作、认证或背书关系。' },
  { title: '开源许可与源码', text: '查看本版本使用的第三方组件、完整版权声明及许可证。\n\n对于许可证要求提供源码的组件，我们将按相应许可履行对应源码、修改内容及构建说明的提供义务。' },
  { title: '使用提示', text: '请仅下载、分享和使用您拥有合法权利或已获授权的文件。\n\nBT 任务在下载过程中也可能向其他用户上传分片；下载完成后，若继续做种，仍会产生上传流量。请根据需要设置网络连接、上传限速及做种选项。\n\n感谢每一位参与测试、反馈问题和支持 BTmobie 的用户。' }
];

export interface LicenseNotice { name: string; files: string[] }
// These notices are copied into the HAP by the existing pinned dependency build.
export const LICENSE_NOTICES: LicenseNotice[] = [
  { name: 'libtorrent', files: ['libtorrent/COPYING', 'libtorrent/LICENSE'] },
  { name: 'FFmpeg', files: ['media/LICENSE.md', 'media/COPYING.LGPLv2.1'] },
  { name: 'dav1d', files: ['media/dav1d-BSD-2-Clause.txt'] },
  { name: '7-Zip', files: ['7zip/License.txt', '7zip/copying.txt', '7zip/unRarLicense.txt'] },
  { name: 'bit7z', files: ['bit7z/LICENSE'] },
  { name: 'libarchive', files: ['archive/COPYING'] },
  { name: 'OpenSSL', files: ['openssl/LICENSE.txt'] },
  { name: 'Boost', files: ['boost/LICENSE_1_0.txt'] },
  { name: 'zlib', files: ['zlib/LICENSE', 'zlib/zlib-license-header.txt'] },
  { name: 'XZ / liblzma', files: ['xz/COPYING', 'xz/COPYING.0BSD', 'xz/COPYING.GPLv2', 'xz/COPYING.GPLv3', 'xz/COPYING.LGPLv2.1'] },
  { name: 'nlohmann/json', files: ['nlohmann-json-LICENSE.txt'] },
  { name: 'cpp-httplib', files: ['cpp-httplib-LICENSE.txt'] },
  { name: 'iTorrent', files: ['BTMobile-iTorrent-LICENSE.txt'] }
];
