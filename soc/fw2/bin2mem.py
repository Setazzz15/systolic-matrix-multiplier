import sys, struct
src, hexout, coeout, depth = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
data = open(src, 'rb').read()
data += b'\0' * (-len(data) % 4)
words = [struct.unpack_from('<I', data, i)[0] for i in range(0, len(data), 4)]
assert len(words) <= depth, f"image {len(words)} words exceeds depth {depth}"
open(hexout, 'w').write(''.join(f'{w:08x}\n' for w in words))
open(coeout, 'w').write('memory_initialization_radix=16;\nmemory_initialization_vector=\n'
                        + ',\n'.join(f'{w:08x}' for w in words) + ';\n')
print(f"{src}: {len(data)} bytes, {len(words)} words")
