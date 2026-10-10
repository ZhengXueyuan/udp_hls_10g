#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""One-off evidence tool (NOT part of the gate): classify every row of
sweep_all_wrappers.txt by an independent text fact, so the false-positive
count does not rest on the checker's own verdict.

Fact used (whitespace-insensitive, CRLF-normalised):
  the five TX single-domain aliases, in their CORRECT direction, are
     assign m_tx_t{data,keep,last,valid} = txsrc_t{data,keep,last,valid};
     assign txsrc_tready                  = m_tx_tready;
  (tready is the mirror pair -- it flows backwards, see the report's note)
  In the PRE-FIX (buggy) direction those five are swapped.

Class:  rev>0 & buggy x5            -> TRUE positive (a stale/archived/mutant
                                       copy that really does carry the defect)
        rev==0 & fixed x5           -> correctly clean
        rev==0 & no txsrc_* at all  -> pre-P6b lineage, correctly clean
        anything else               -> FALSE POSITIVE / unclassified
"""
import re
import sys

DATA = ('tdata', 'tkeep', 'tlast', 'tvalid')
SWEEP = r'_proj_10g\notes\p7b_aliasgate_20261010\sweep_all_wrappers.txt'


def count(text, x, y):
    return 1 if re.search(r'\bassign\s+%s\s*=\s*%s\s*;' % (x, y), text) else 0


def main():
    rows = []
    with open(SWEEP, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            m = re.match(r'\s+SWEEP (\S+)\s+rc=(\d)\s+rev/multi=(\d)/(\d)', line)
            if m:
                rows.append((m.group(1), int(m.group(2)), int(m.group(3))))
    print('# independent classification of the sweep (fact = literal form of the')
    print('# five alias lines; whitespace-insensitive; ready pair checked in ITS')
    print('# correct direction = the mirror of the data/valid pairs)')
    print('%-70s %4s %5s  %s' % ('file', 'rc', 'rev', 'text fact'))
    n_true = n_clean = n_fp = 0
    for rel, rc, rev in rows:
        with open(rel, 'rb') as f:
            raw = f.read().decode('utf-8', 'replace').replace('\r\n', '\n')
        bug = sum(count(raw, 'txsrc_' + n, 'm_tx_' + n) for n in DATA)
        bug += count(raw, 'm_tx_tready', 'txsrc_tready')
        good = sum(count(raw, 'm_tx_' + n, 'txsrc_' + n) for n in DATA)
        good += count(raw, 'txsrc_tready', 'm_tx_tready')
        any_ts = 'txsrc_tdata' in raw
        if rev > 0 and bug == 5 and good == 0:
            fact = 'buggy x5 -> TRUE positive (stale/archived/mutant copy)'
            n_true += 1
        elif rev == 0 and good == 5 and bug == 0:
            fact = 'fixed x5 -> correctly clean'
            n_clean += 1
        elif rev == 0 and not any_ts:
            fact = 'pre-P6b lineage (no txsrc_* at all) -> correctly clean'
            n_clean += 1
        else:
            fact = '*** FALSE POSITIVE / unclassified (bug=%d good=%d) ***' % (bug, good)
            n_fp += 1
        print('%-70s %4d %5d  %s' % (rel, rc, rev, fact))
    print()
    print('# totals: files=%d  true-positive=%d  clean=%d  '
          'FALSE-POSITIVE/unclassified=%d' % (len(rows), n_true, n_clean, n_fp))
    return 1 if n_fp else 0


if __name__ == '__main__':
    sys.exit(main())
