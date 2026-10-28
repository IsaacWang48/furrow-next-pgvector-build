"""Bounded static PE32+ compatibility checks; never loads/executes a DLL."""
import hashlib
import json
import struct
import sys
from pathlib import Path


class PE:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        assert self.data[:2] == b'MZ', 'DOS signature'
        pe = self.u32(0x3c)
        assert self.read(pe, 4) == b'PE\0\0', 'PE signature'
        assert self.u16(pe + 4) == 0x8664, 'AMD64 required'
        count = self.u16(pe + 6)
        optsize = self.u16(pe + 20)
        opt = pe + 24
        assert self.u16(opt) == 0x20b and optsize >= 240, 'PE32+ required'
        assert self.u32(opt + 108) >= 16, 'directory count'
        self.dirs = [tuple(self.unpack('<II', opt + 112 + i * 8)) for i in range(16)]
        self.sections = []
        for i in range(count):
            s = opt + optsize + i * 40
            self.sections.append((self.u32(s + 12), self.u32(s + 20), self.u32(s + 16)))

    def read(self, pos, size):
        assert 0 <= pos <= len(self.data) and 0 <= size <= len(self.data) - pos, 'bounds'
        return self.data[pos:pos + size]

    def unpack(self, fmt, pos):
        return struct.unpack(fmt, self.read(pos, struct.calcsize(fmt)))

    def u16(self, pos):
        return self.unpack('<H', pos)[0]

    def u32(self, pos):
        return self.unpack('<I', pos)[0]

    def offset(self, rva, size=1):
        for va, raw, length in self.sections:
            if va <= rva and rva - va + size <= length:
                pos = raw + rva - va
                self.read(pos, size)
                return pos
        raise AssertionError('RVA not backed by raw bytes')

    def string(self, rva):
        pos = self.offset(rva)
        end = self.data.find(b'\0', pos, min(pos + 4096, len(self.data)))
        assert end >= pos, 'unterminated string'
        return self.data[pos:end].decode('ascii')

    def exports(self):
        rva, size = self.dirs[0]
        assert rva and size, 'export directory required'
        p = self.offset(rva, 40)
        functions, names = self.u32(p + 20), self.u32(p + 24)
        assert names <= functions <= 100000, 'export count'
        f, n, o = self.u32(p + 28), self.u32(p + 32), self.u32(p + 36)
        result = {}
        for i in range(names):
            name = self.string(self.u32(self.offset(n + 4 * i, 4)))
            ordinal = self.u16(self.offset(o + 2 * i, 2))
            assert ordinal < functions, 'export ordinal bounds'
            target = self.u32(self.offset(f + 4 * ordinal, 4))
            result[name] = {'rva': target, 'forwarded': rva <= target < rva + size}
        return result

    def imports(self):
        assert self.dirs[13] == (0, 0), 'Unreviewed delay imports'
        rva, size = self.dirs[1]
        assert rva and size, 'import directory required'
        result = {}
        for i in range(size // 20):
            p = self.offset(rva + 20 * i, 20)
            desc = self.unpack('<IIIII', p)
            if not any(desc):
                return result
            original, _, _, name, thunk = desc
            module = self.string(name).lower()
            assert module not in result, 'duplicate import module'
            result[module] = []
            for j in range(100000):
                value = self.unpack('<Q', self.offset((original or thunk) + 8 * j, 8))[0]
                if not value:
                    break
                assert not value & (1 << 63), 'Unreviewed ordinal import'
                result[module].append(self.string(value + 2))
            else:
                raise AssertionError('unbounded import table')
        raise AssertionError('unterminated import descriptors')

    def magic(self, exports):
        exp = exports['Pg_magic_func']
        assert not exp['forwarded'], 'forwarded magic'
        rva = exp['rva']
        # Follow bounded direct near jumps using the UPDATED instruction RVA.
        for _ in range(3):
            p = self.offset(rva, 8)
            code = self.read(p, 8)
            if code[0] == 0xe9:
                rva = rva + 5 + self.unpack('<i', p + 1)[0]
                continue
            assert code[:3] == b'\x48\x8d\x05' and code[7] == 0xc3, 'Unreviewed magic function form'
            value = rva + 7 + self.unpack('<i', p + 3)[0]
            raw = self.read(self.offset(value, 56), 56)
            fields = struct.unpack('<6I', raw[:24])
            assert fields == (56, 1700, 100, 32, 64, 1), 'PG17 ABI magic mismatch'
            assert raw[24:].split(b'\0', 1)[0] == b'PostgreSQL', 'ABI extra mismatch'
            return {'length': fields[0], 'postgresMajorCode': fields[1], 'functionMaxArgs': fields[2], 'indexMaxKeys': fields[3], 'nameDataLength': fields[4], 'float8ByValue': fields[5], 'abiExtra': 'PostgreSQL'}
        raise AssertionError('Unreviewed magic jump chain')


def inspect(dll, postgres, lock):
    native, backend = PE(dll), PE(postgres)
    sha = lambda b: hashlib.sha256(b).hexdigest()
    assert sha(backend.data) == lock['postgres']['files']['bin/postgres.exe'], 'Wrong prepared backend'
    exports, target = native.exports(), backend.exports()
    imports = native.imports()
    assert set(imports) <= set(lock['toolchain']['allowedImports']), 'Unexplained dependency module'
    assert 'postgres.exe' in imports and imports['postgres.exe'], 'Expected backend linkage absent'
    missing = [s for s in imports['postgres.exe'] if s not in target or target[s]['forwarded']]
    assert not missing, 'Missing/forwarded backend symbols: ' + repr(missing)
    magic = native.magic(exports)
    return {'staticOnly': True, 'dllSha256': sha(native.data), 'backendSha256': sha(backend.data), 'machine': 'AMD64', 'magic': magic, 'imports': imports, 'missingBackendImports': missing, 'backendNamedExports': len(target), 'delayImports': 0, 'ordinalImports': 0, 'certificateTableBytes': native.dirs[4][1], 'provenanceOrRuntimeVerification': 'NOT_ESTABLISHED_BY_THIS_CHECK'}


if __name__ == '__main__':
    assert len(sys.argv) == 5, 'dll postgres lock output'
    result = inspect(sys.argv[1], sys.argv[2], json.loads(Path(sys.argv[3]).read_text()))
    Path(sys.argv[4]).write_text(json.dumps(result, indent=2) + '\n')
    print('PE_STATIC_COMPATIBILITY_PASS')
