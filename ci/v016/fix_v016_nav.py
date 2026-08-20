#!/usr/bin/env python3
from pathlib import Path

path = Path('iTorrent/Screens/TorrentList/TorrentListViewController.swift')
text = path.read_text(encoding='utf-8')
old_share = '''        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "分享",
            image: UIImage(systemName: "square.and.arrow.up"),
            target: self,
            action: #selector(shareImage)
        )
'''
new_share = '''        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareImage)
        )
'''
old_back = '''        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "返回",
            image: UIImage(systemName: "chevron.left"),
            target: self,
            action: #selector(requestClose)
        )
'''
new_back = '''        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "返回",
            style: .plain,
            target: self,
            action: #selector(requestClose)
        )
'''
if new_share not in text:
    if old_share not in text: raise RuntimeError('image viewer share button anchor missing')
    text = text.replace(old_share, new_share, 1)
if new_back not in text:
    if old_back not in text: raise RuntimeError('text editor back button anchor missing')
    text = text.replace(old_back, new_back, 1)
path.write_text(text, encoding='utf-8')
print('V0.1.6 UIKit bar button compatibility finalized')
