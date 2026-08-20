#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding='utf-8')
    if new in text:
        print(f'{label}: already applied')
        return
    if old not in text:
        raise RuntimeError(f'{label}: anchor not found in {path}')
    path.write_text(text.replace(old, new, 1), encoding='utf-8')
    print(f'{label}: applied')


def main() -> int:
    root = Path.cwd()
    project = root / 'iTorrent.xcodeproj/project.pbxproj'
    text = project.read_text(encoding='utf-8')
    text = text.replace('CURRENT_PROJECT_VERSION = 14;\n\t\t\t\tMARKETING_VERSION = 0.1.4;',
                        'CURRENT_PROJECT_VERSION = 16;\n\t\t\t\tMARKETING_VERSION = 0.1.5;')
    text = text.replace('CURRENT_PROJECT_VERSION = 15;\n\t\t\t\tMARKETING_VERSION = 0.1.4;',
                        'CURRENT_PROJECT_VERSION = 16;\n\t\t\t\tMARKETING_VERSION = 0.1.5;')
    project.write_text(text, encoding='utf-8')

    archive = root / 'Submodules/SwiftVLC/Sources/SwiftVLC/Archive/ArchiveExtractor.swift'
    old_terms = '''            "decrypt",\n            "密码",\n            "加密"\n'''
    new_terms = '''            "decrypt",\n            "authentication",\n            "crypto",\n            "incorrect passphrase",\n            "passphrase required",\n            "密码",\n            "加密"\n'''
    replace_once(archive, old_terms, new_terms, 'password error detection')

    torrent_service = root / 'iTorrent/Services/TorrentService/TorrentService.swift'
    old_combine = '''            Publishers.combineLatest(\n                preferences.$storageScopes,\n                preferences.$btMobileManagedStorageScopes\n            )\n            .sink { [unowned self] external, managed in\n                session.storages = external.merging(managed) { external, _ in external }\n            }\n'''
    new_combine = '''            Publishers.CombineLatest(\n                preferences.$storageScopes,\n                preferences.$btMobileManagedStorageScopes\n            )\n            .sink { [unowned self] values in\n                let (external, managed) = values\n                session.storages = external.merging(managed) { external, _ in external }\n            }\n'''
    replace_once(torrent_service, old_combine, new_combine, 'managed storage CombineLatest')

    path = root / 'iTorrent/Screens/TorrentList/TorrentListViewController.swift'
    text = path.read_text(encoding='utf-8')

    old_size = '''        return urls.compactMap { url in\n            let values = try? url.resourceValues(forKeys: keys)\n            if values?.isHidden == true { return nil }\n            return Item(\n                url: url,\n                isDirectory: values?.isDirectory == true,\n                size: Int64(values?.fileSize ?? 0),\n                modificationDate: values?.contentModificationDate\n            )\n        }\n'''
    new_size = '''        return urls.compactMap { url in\n            let values = try? url.resourceValues(forKeys: keys)\n            if values?.isHidden == true { return nil }\n            let isDirectory = values?.isDirectory == true\n            let logicalSize: Int64\n            if isDirectory {\n                logicalSize = 0\n            } else if let fileSize = values?.fileSize {\n                logicalSize = Int64(fileSize)\n            } else if let attributes = try? fileManager.attributesOfItem(atPath: url.path),\n                      let number = attributes[.size] as? NSNumber {\n                logicalSize = number.int64Value\n            } else {\n                logicalSize = 0\n            }\n            return Item(\n                url: url,\n                isDirectory: isDirectory,\n                size: logicalSize,\n                modificationDate: values?.contentModificationDate\n            )\n        }\n'''
    if new_size not in text:
        if old_size not in text: raise RuntimeError('file size block anchor not found')
        text = text.replace(old_size, new_size, 1)

    anchor = 'final class BTFileManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {'
    cell = '''final class BTFileManagerCell: UITableViewCell {\n    static let reuseIdentifier = "BTFileManagerCellV015"\n\n    private let fileIconView = UIImageView()\n    private let nameLabel = UILabel()\n    private let detailLabel = UILabel()\n    private let sizeLabel = UILabel()\n\n    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {\n        super.init(style: style, reuseIdentifier: reuseIdentifier)\n        fileIconView.translatesAutoresizingMaskIntoConstraints = false\n        fileIconView.contentMode = .scaleAspectFit\n        fileIconView.tintColor = .secondaryLabel\n        nameLabel.translatesAutoresizingMaskIntoConstraints = false\n        nameLabel.font = .systemFont(ofSize: 15, weight: .regular)\n        nameLabel.textColor = .label\n        nameLabel.numberOfLines = 2\n        nameLabel.lineBreakMode = .byTruncatingMiddle\n        detailLabel.translatesAutoresizingMaskIntoConstraints = false\n        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)\n        detailLabel.textColor = .tertiaryLabel\n        detailLabel.numberOfLines = 1\n        sizeLabel.translatesAutoresizingMaskIntoConstraints = false\n        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)\n        sizeLabel.textColor = .secondaryLabel\n        sizeLabel.textAlignment = .right\n        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)\n        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)\n        contentView.addSubview(fileIconView)\n        contentView.addSubview(nameLabel)\n        contentView.addSubview(detailLabel)\n        contentView.addSubview(sizeLabel)\n        NSLayoutConstraint.activate([\n            fileIconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),\n            fileIconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),\n            fileIconView.widthAnchor.constraint(equalToConstant: 25),\n            fileIconView.heightAnchor.constraint(equalToConstant: 25),\n            sizeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -13),\n            sizeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),\n            sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),\n            sizeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 88),\n            nameLabel.leadingAnchor.constraint(equalTo: fileIconView.trailingAnchor, constant: 11),\n            nameLabel.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -9),\n            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),\n            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),\n            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -9),\n            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),\n            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -7)\n        ])\n    }\n\n    @available(*, unavailable)\n    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }\n\n    func configure(item: BTFileManagerService.Item, iconName: String) {\n        fileIconView.image = UIImage(systemName: iconName)\n        nameLabel.text = item.name\n        if item.isDirectory {\n            sizeLabel.text = "文件夹"\n            detailLabel.text = "目录"\n        } else {\n            sizeLabel.text = ByteCountFormatter.string(fromByteCount: max(item.size, 0), countStyle: .file)\n            let type = item.pathExtension.isEmpty ? "文件" : item.pathExtension.uppercased()\n            if let date = item.modificationDate {\n                detailLabel.text = "\\(type) · \\(Self.dateFormatter.string(from: date))"\n            } else {\n                detailLabel.text = type\n            }\n        }\n    }\n\n    private static let dateFormatter: DateFormatter = {\n        let formatter = DateFormatter()\n        formatter.locale = Locale(identifier: "zh_CN")\n        formatter.dateFormat = "MM-dd HH:mm"\n        return formatter\n    }()\n}\n\n'''
    if 'final class BTFileManagerCell: UITableViewCell {' not in text:
        if anchor not in text: raise RuntimeError('file manager controller anchor not found')
        text = text.replace(anchor, cell + anchor, 1)

    text = text.replace('tableView.rowHeight = 58', 'tableView.rowHeight = 66', 1)
    if 'tableView.register(BTFileManagerCell.self' not in text:
        text = text.replace('''        tableView.rowHeight = 66\n        view.addSubview(tableView)\n''', '''        tableView.rowHeight = 66\n        tableView.register(BTFileManagerCell.self, forCellReuseIdentifier: BTFileManagerCell.reuseIdentifier)\n        view.addSubview(tableView)\n''', 1)

    old_cell = '''    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {\n        let id = "BTFileManagerCell"\n        let cell = tableView.dequeueReusableCell(withIdentifier: id) ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)\n        let item = items[indexPath.row]\n        var content = cell.defaultContentConfiguration()\n        content.text = item.name\n        content.image = UIImage(systemName: iconName(for: item))\n        content.secondaryText = item.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)\n        content.secondaryTextProperties.color = .secondaryLabel\n        cell.contentConfiguration = content\n        cell.accessoryType = item.isDirectory ? .disclosureIndicator : .none\n        return cell\n    }\n'''
    new_cell = '''    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {\n        let item = items[indexPath.row]\n        guard let cell = tableView.dequeueReusableCell(\n            withIdentifier: BTFileManagerCell.reuseIdentifier,\n            for: indexPath\n        ) as? BTFileManagerCell else {\n            return UITableViewCell()\n        }\n        cell.configure(item: item, iconName: iconName(for: item))\n        cell.accessoryType = item.isDirectory ? .disclosureIndicator : .none\n        return cell\n    }\n'''
    if new_cell not in text:
        if old_cell not in text: raise RuntimeError('cellForRow block not found')
        text = text.replace(old_cell, new_cell, 1)

    ctx_start = '    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {'
    ctx_end = '    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {'
    if 'UIAction(title: "文件信息"' not in text:
        start = text.index(ctx_start)
        end = text.index(ctx_end, start)
        replacement = '''    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {\n        let item = items[indexPath.row]\n        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in\n            guard let self else { return nil }\n            var actions: [UIMenuElement] = []\n            if item.isDirectory {\n                actions.append(UIAction(title: "打开文件夹", image: UIImage(systemName: "folder")) { [weak self] _ in\n                    self?.navigationController?.pushViewController(BTFileManagerViewController(directoryURL: item.url), animated: true)\n                })\n                actions.append(UIAction(title: "设为下载目录", image: UIImage(systemName: "arrow.down.to.line.compact")) { [weak self] _ in\n                    try? self?.service.setDownloadDirectory(item.url)\n                    self?.reload()\n                })\n            } else if item.isArchive {\n                actions.append(UIAction(title: "解压", image: UIImage(systemName: "archivebox")) { [weak self] _ in self?.extractArchive(item.url, password: nil) })\n                actions.append(UIAction(title: "密码解压", image: UIImage(systemName: "lock.open")) { [weak self] _ in self?.promptArchivePassword(item.url) })\n                actions.append(UIAction(title: "用其他 App 打开", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share(item.url, sourceView: tableView.cellForRow(at: indexPath)) })\n            } else if item.isVideo {\n                actions.append(UIAction(title: "播放", image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.navigateToVideo(item.url) })\n                actions.append(UIAction(title: "用其他 App 打开", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share(item.url, sourceView: tableView.cellForRow(at: indexPath)) })\n            } else {\n                actions.append(UIAction(title: "打开 / 分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share(item.url, sourceView: tableView.cellForRow(at: indexPath)) })\n            }\n            actions.append(UIAction(title: "文件信息", image: UIImage(systemName: "info.circle")) { [weak self] _ in self?.presentFileInfo(item) })\n            actions.append(UIAction(title: "重命名", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRename(item.url) })\n            actions.append(UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmDelete(item.url) })\n            return UIMenu(children: actions)\n        }\n    }\n\n'''
        text = text[:start] + replacement + text[end:]

    if 'leadingSwipeActionsConfigurationForRowAt' not in text:
        lead = '''    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {\n        let item = items[indexPath.row]\n        let info = UIContextualAction(style: .normal, title: "信息") { [weak self] _, _, done in\n            self?.presentFileInfo(item)\n            done(true)\n        }\n        info.image = UIImage(systemName: "info.circle")\n        return UISwipeActionsConfiguration(actions: [info])\n    }\n\n'''
        text = text.replace(ctx_end, lead + ctx_end, 1)

    if 'private func presentFileInfo(_ item:' not in text:
        helper = '''    private func presentFileInfo(_ item: BTFileManagerService.Item) {\n        let type: String\n        if item.isDirectory { type = "文件夹" }\n        else if item.pathExtension.isEmpty { type = "文件" }\n        else { type = item.pathExtension.uppercased() }\n        let size = item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: max(item.size, 0), countStyle: .file)\n        let modified: String\n        if let date = item.modificationDate {\n            let formatter = DateFormatter()\n            formatter.locale = Locale(identifier: "zh_CN")\n            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"\n            modified = formatter.string(from: date)\n        } else { modified = "未知" }\n        let message = "类型：\\(type)\\n大小：\\(size)\\n修改时间：\\(modified)\\n位置：\\(relativePath(item.url.deletingLastPathComponent()))"\n        let alert = UIAlertController(title: item.name, message: message, preferredStyle: .alert)\n        alert.addAction(UIAlertAction(title: "好", style: .default))\n        present(alert, animated: true)\n    }\n\n'''
        text = text.replace('    private func iconName(for item: BTFileManagerService.Item) -> String {', helper + '    private func iconName(for item: BTFileManagerService.Item) -> String {', 1)

    text = text.replace('// MARK: - BT Mobile 0.1.4 File Manager', '// MARK: - BT Mobile 0.1.5 File Manager', 1)
    path.write_text(text, encoding='utf-8')
    print('V0.1.5 UI/version/source transforms applied')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'apply_v015 failed: {exc}', file=sys.stderr)
        raise
