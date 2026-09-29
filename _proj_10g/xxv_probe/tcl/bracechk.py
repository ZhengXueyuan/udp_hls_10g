import sys

p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
lines = s.split('\n')
depth = 0
i = 0
n = len(s)
line = 1
while i < n:
    ch = s[i]
    if ch == '\n':
        line += 1
        i += 1
        continue
    if ch == '\\':
        # backslash substitution: consume next char (and handle \newline)
        i += 2
        continue
    if ch == '"':
        i += 1
        while i < n and s[i] != '"':
            if s[i] == '\\':
                i += 2
                continue
            if s[i] == '[':
                # command subst inside quotes: skip balanced
                d = 1
                i += 1
                while i < n and d:
                    if s[i] == '\\':
                        i += 2
                        continue
                    if s[i] == '[':
                        d += 1
                    elif s[i] == ']':
                        d -= 1
                    if s[i] == '\n':
                        line += 1
                    i += 1
                continue
            if s[i] == '\n':
                line += 1
            i += 1
        i += 1
        continue
    if ch == '[':
        d = 1
        i += 1
        while i < n and d:
            if s[i] == '\\':
                i += 2
                continue
            if s[i] == '"':
                i += 1
                while i < n and s[i] != '"':
                    if s[i] == '\\':
                        i += 2
                        continue
                    i += 1
                i += 1
                continue
            if s[i] == '[':
                d += 1
            elif s[i] == ']':
                d -= 1
            if s[i] == '\n':
                line += 1
            i += 1
        continue
    if ch == '{':
        depth += 1
        i += 1
        continue
    if ch == '}':
        depth -= 1
        if depth < 0:
            print('NEG depth at line', line)
        i += 1
        continue
    i += 1
print('final brace depth =', depth)
