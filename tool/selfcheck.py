# -*- coding: utf-8 -*-
"""静态自检：括号是否配对闭合、相对 import 是否存在。

在没有 Dart SDK 的机器上，这是能做的最高性价比检查。

两个坑，都踩过：
1. 只数括号**总数**不够：`children: [ ... ),` 这种「数量对、类型错位」的写法
   总数照样平衡，Dart 却报 "Can't find ']' to match '['"（v1.7 挂过一次）。
   → 用栈做类型匹配，遇到 ) ] } 必须和栈顶的 ( [ { 是同一对。
2. 字符串插值里也可能有引号：`'${neg ? '-' : ''}'`。
   简单按引号切会把字符串切碎、连带后面的括号全错位。
   → 遇到 `${` 时整体跳过（内部括号不参与匹配），并保留换行以维持行号。
"""
import io
import os
import re
import sys

BACKSLASH = chr(92)
PAIRS = {')': '(', ']': '[', '}': '{'}


def _skip_interp(s, i):
    """s[i] 是 '{'，返回与之配对的 '}' 之后的位置"""
    n = len(s)
    depth = 0
    while i < n:
        c = s[i]
        if c == "'" or c == '"':
            i, _ = _skip_string(s, i)
            continue
        if c == '{':
            depth += 1
            i += 1
            continue
        if c == '}':
            depth -= 1
            i += 1
            if depth == 0:
                return i
            continue
        i += 1
    return n


def _skip_string(s, i):
    """s[i] 是引号，返回 (字符串结束后的位置, 其中包含的换行)"""
    q = s[i]
    triple = s.startswith(q * 3, i)
    end = q * 3 if triple else q
    i += len(end)
    n = len(s)
    newlines = []
    while i < n:
        if s.startswith(end, i):
            i += len(end)
            return i, newlines
        c = s[i]
        if c == BACKSLASH:
            if s[i + 1:i + 2] == '\n':
                newlines.append('\n')
            i += 2
            continue
        if c == '$' and s.startswith('${', i):
            j = _skip_interp(s, i + 1)
            newlines.extend([ch for ch in s[i:j] if ch == '\n'])
            i = j
            continue
        if c == '\n':
            newlines.append('\n')
            if not triple:
                # 单行字符串遇到换行（语法上非法），宽容处理
                return i + 1, newlines
            i += 1
            continue
        i += 1
    return i, newlines


def strip_code(s):
    """去掉注释与字符串内容，保留换行（行号才对得上）"""
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
                if s[i] == '\n':
                    out.append('\n')
                i += 1
            i += 2
        elif c == "'" or c == '"':
            i, newlines = _skip_string(s, i)
            out.extend(newlines)
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def check_nesting(path, code):
    stack = []
    line = 1
    for ch in code:
        if ch == '\n':
            line += 1
        elif ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            if not stack:
                return '%s:%d 多余的 %s（前面没有对应的开括号）' % (path, line, ch)
            top, open_line = stack.pop()
            if top != PAIRS[ch]:
                return '%s:%d 遇到 %s，但第 %d 行打开的 %s 还没闭合' % (
                    path, line, ch, open_line, top)
    if stack:
        top, open_line = stack[-1]
        return '%s: 第 %d 行的 %s 没有闭合' % (path, open_line, top)
    return None


def main():
    problems = []
    files = []
    for root, _, fs in os.walk('lib'):
        for f in fs:
            if f.endswith('.dart'):
                files.append(os.path.join(root, f))

    for p in files:
        src = io.open(p, encoding='utf-8').read()
        err = check_nesting(p, strip_code(src))
        if err:
            problems.append(err)
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
        print('OK: 括号按类型配对，相对 import 全部存在')
    print('dart 文件数: %d' % len(files))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
