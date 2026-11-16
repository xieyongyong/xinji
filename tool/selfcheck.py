# -*- coding: utf-8 -*-
"""静态自检：括号是否闭合、相对 import 是否存在。
在没有 Dart SDK 的机器上，这是能做的最高性价比检查。"""
import io
import os
import re
import sys

BACKSLASH = chr(92)


def strip_code(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i + 1] == '/'):
                i += 1
            i += 2
        elif c == "'" or c == '"':
            q = c
            i += 1
            while i < n:
                if s[i] == BACKSLASH:
                    i += 2
                    continue
                if s[i] == q:
                    i += 1
                    break
                i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def main():
    problems = []
    files = []
    for root, _, fs in os.walk('lib'):
        for f in fs:
            if f.endswith('.dart'):
                files.append(os.path.join(root, f))

    for p in files:
        src = io.open(p, encoding='utf-8').read()
        # 逐行累计深度：单行内剥离字符串与注释后统计，跨行字符串不会被误算
        depth = 0
        for line in src.split('\n'):
            code = strip_code(line)
            depth += code.count('{') - code.count('}')
        if depth != 0:
            problems.append('%s: 大括号最终深度 %d（应为 0）' % (p, depth))
        folder = os.path.dirname(p)
        for m in re.finditer(r"import\s+'([^']+)'", src):
            imp = m.group(1)
            if imp.startswith('dart:') or imp.startswith('package:'):
                continue
            target = os.path.normpath(os.path.join(folder, imp))
            if not os.path.exists(target):
                problems.append('%s: import 不存在 -> %s' % (p, imp))

    if problems:
        print('\n'.join(problems))
    else:
        print('OK: 括号平衡，相对 import 全部存在')
    print('dart 文件数: %d' % len(files))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
