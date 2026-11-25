#!/usr/bin/env python3
"""Create independent SHA3-256 oracles without using the HDL permutation."""
import argparse
import hashlib
import json
import random
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
rng = random.Random(20261111)
messages = [('zero', b'\x00'), ('ff', b'\xff'), ('a', b'a'), ('abc', b'abc')]
for length in [7, 8, 31, 32, 63, 64, 134, 135, 136, 137, 271, 272, 273, 4096, 65536]:
    messages.append((f'random_{length}', bytes(rng.getrandbits(8) for _ in range(length))))
messages.append(('nist_a3_200', b'\xa3' * 200))
for index in range(20):
    length = rng.randint(1, 3072)
    messages.append((f'random_extra_{index}', rng.randbytes(length)))
metadata = []
with (args.output / 'vectors.txt').open('w') as output:
    for name, message in messages:
        digest = hashlib.sha3_256(message).digest()
        # The literal's leftmost byte occupies bits 255:248, but core byte 0 is 7:0.
        output.write(f'{len(message)} {digest[::-1].hex()} ' + ' '.join(f'{b:02x}' for b in message) + '\n')
        metadata.append({'name': name, 'bytes': len(message), 'sha3_256': digest.hex()})
(args.output / 'vectors.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(f'Generated {len(messages)} nonempty vectors; empty input is unsupported by the upstream port.')
