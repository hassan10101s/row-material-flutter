import sys
p = 'lib/core/database/database_helper.dart'
with open(p, encoding='utf-8') as f:
    s = f.read()
# add version to qc_goals
start = s.find('CREATE TABLE IF NOT EXISTS qc_goals')
if start >= 0:
    end = s.find(\"''');\", start)
    if end >= 0:
        block = s[start:end+5]
        if 'version INTEGER' not in block:
            old = '        updated_by TEXT'
            new = old + ',\\n        version INTEGER NOT NULL DEFAULT 1'
            block2 = block.replace(old, new)
            s2 = s[:start] + block2 + s[end+5:]
            with open(p, 'w', encoding='utf-8') as f:
                f.write(s2)
            print('ok1')
        else:
            print('a1')
    else:
        print('e1')
else:
    print('s1')
