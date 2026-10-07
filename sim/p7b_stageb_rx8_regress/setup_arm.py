"""setup_arm.py -- place the mirror tree into the state of one experiment arm.

Arms (E1 = "is the 16-gate matrix blind to a broken byte in rtl/app_pattern.v?",
      done on the MIRROR copy of the gate machinery / rtl, never on the real tree):

  M0_pristine     mirror = real workspace rtl/app_pattern.v (R1 version)
  M1_mutS_blind   mirror/rtl/app_pattern.v := mutS (1 byte deleted inside `ifdef P7B_10G);
                  manifests / gate bats UNCHANGED      -> expect the gate to still pass
  M2_mutS_inset   same mutS file, but the chain gate's declared file list
                  (mirror/sim/p4gates/chain_src.f) AND the bat's xvlog list
                  now include rtl/app_pattern.v        -> expect the gate to go red
  M3_mutB_inset   semantic 1-byte mutant (compiles), same "in set" wiring
                                                       -> expect pass (nothing instantiates it)

usage: python setup_arm.py M0_pristine|M1_mutS_blind|M2_mutS_inset|M3_mutB_inset
"""
import io, os, shutil, sys, hashlib

SC   = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(SC, '..', '..'))
MIR  = os.path.join(SC, 'mirror')
MARK = os.path.join(SC, 'mirror_arm.txt')

def sha(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()

def reset_bat():
    """restore the mirror's chain gate bat from the real repo"""
    shutil.copy2(os.path.join(REPO, 'sim', 'p4sim', 'run_tb_p4_chain.bat'),
                 os.path.join(MIR, 'sim', 'p4sim', 'run_tb_p4_chain.bat'))

def reset_manifest():
    shutil.copy2(os.path.join(REPO, 'sim', 'p4gates', 'chain_src.f'),
                 os.path.join(MIR, 'sim', 'p4gates', 'chain_src.f'))

def put_src(variant):
    if variant is None:
        shutil.copy2(os.path.join(REPO, 'rtl', 'app_pattern.v'),
                     os.path.join(MIR, 'rtl', 'app_pattern.v'))
    else:
        shutil.copy2(os.path.join(SC, 'mut', 'app_pattern_%s.v' % variant),
                     os.path.join(MIR, 'rtl', 'app_pattern.v'))

def add_to_set():
    # manifest
    p = os.path.join(MIR, 'sim', 'p4gates', 'chain_src.f')
    t = io.open(p, 'r', encoding='utf-8').read()
    assert 'app_pattern' not in t
    t = t.replace('rtl/tx_arb.v\n', 'rtl/tx_arb.v\nrtl/app_pattern.v\n')
    io.open(p, 'w', encoding='utf-8', newline='').write(t)
    # bat: insert the file into the xvlog list, right after tx_arb.v
    p = os.path.join(MIR, 'sim', 'p4sim', 'run_tb_p4_chain.bat')
    t = io.open(p, 'r', encoding='utf-8').read()
    assert t.count('rtl\\tx_arb.v') == 1
    t = t.replace('  %REPO_ROOT%\\rtl\\tx_arb.v ^\n',
                  '  %REPO_ROOT%\\rtl\\tx_arb.v ^\n  %REPO_ROOT%\\rtl\\app_pattern.v ^\n')
    io.open(p, 'w', encoding='utf-8', newline='').write(t)

def add_macro():
    """add -d P7B_10G to BOTH xvlog invocations of the mirror chain gate bat"""
    p = os.path.join(MIR, 'sim', 'p4sim', 'run_tb_p4_chain.bat')
    t = io.open(p, 'r', encoding='utf-8').read()
    a = 'xvlog.bat -work xil_defaultlib -f hls_files.f'
    b = 'xvlog.bat -work xil_defaultlib -d P7B_10G -f hls_files.f'
    assert t.count(a) == 1, t.count(a)
    t = t.replace(a, b)
    a2 = 'xvlog.bat -work xil_defaultlib ^'
    b2 = 'xvlog.bat -work xil_defaultlib -d P7B_10G ^'
    assert t.count(a2) == 1, t.count(a2)
    t = t.replace(a2, b2)
    io.open(p, 'w', encoding='utf-8', newline='').write(t)

def main(arm):
    reset_bat(); reset_manifest()
    if arm == 'M0_pristine':
        put_src(None)
    elif arm == 'M1_mutS_blind':
        put_src('mutS')
    elif arm == 'M2_mutS_inset':
        put_src('mutS'); add_to_set()
    elif arm == 'M3_mutB_inset':
        put_src('mutB'); add_to_set()
    elif arm == 'M2p_mutS_inset_macro':
        put_src('mutS'); add_to_set(); add_macro()
    elif arm == 'M0p_pristine_inset_macro':
        put_src(None); add_to_set(); add_macro()
    else:
        raise SystemExit('unknown arm %s' % arm)
    io.open(MARK, 'w', encoding='utf-8').write(arm + '\n')
    print('arm %s ready' % arm)
    print('  mirror/rtl/app_pattern.v   sha256 =', sha(os.path.join(MIR, 'rtl', 'app_pattern.v'))[:16])
    print('  mirror/sim/p4gates/chain_src.f  has app_pattern:',
          'app_pattern' in io.open(os.path.join(MIR, 'sim', 'p4gates', 'chain_src.f'), encoding='utf-8').read())
    print('  mirror/sim/p4sim/run_tb_p4_chain.bat has app_pattern:',
          'app_pattern' in io.open(os.path.join(MIR, 'sim', 'p4sim', 'run_tb_p4_chain.bat'), encoding='utf-8').read())

if __name__ == '__main__':
    main(sys.argv[1])
