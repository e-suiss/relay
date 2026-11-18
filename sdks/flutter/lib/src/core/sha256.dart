const int _mask = 0xffffffff;

const String _kHex =
    '428a2f9871374491b5c0fbcfe9b5dba53956c25b59f111f1923f82a4ab1c5ed5'
    'd807aa9812835b01243185be550c7dc372be5d7480deb1fe9bdc06a7c19bf174'
    'e49b69c1efbe47860fc19dc6240ca1cc2de92c6f4a7484aa5cb0a9dc76f988da'
    '983e5152a831c66db00327c8bf597fc7c6e00bf3d5a7914706ca635114292967'
    '27b70a852e1b21384d2c6dfc53380d13650a7354766a0abb81c2c92e92722c85'
    'a2bfe8a1a81a664bc24b8b70c76c51a3d192e819d6990624f40e3585106aa070'
    '19a4c1161e376c082748774c34b0bcb5391c0cb34ed8aa4a5b9cca4f682e6ff3'
    '748f82ee78a5636f84c878148cc7020890befffaa4506cebbef9a3f7c67178f2';

const String _hHex =
    '6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19';

List<int> _words(String hex) => <int>[
  for (int i = 0; i < hex.length; i += 8)
    int.parse(hex.substring(i, i + 8), radix: 16),
];

final List<int> _k = _words(_kHex);

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

/// The lowercase hex SHA-256 digest of [data].
String relaySha256Hex(List<int> data) {
  final List<int> h = _words(_hHex);
  final int bits = data.length * 8;
  final List<int> m = <int>[...data, 0x80];
  while (m.length % 64 != 56) {
    m.add(0);
  }
  for (int i = 7; i >= 0; i--) {
    m.add((bits >> (i * 8)) & 0xff);
  }
  final List<int> w = List<int>.filled(64, 0);
  for (int chunk = 0; chunk < m.length; chunk += 64) {
    for (int t = 0; t < 16; t++) {
      final int j = chunk + t * 4;
      w[t] = (m[j] << 24) | (m[j + 1] << 16) | (m[j + 2] << 8) | m[j + 3];
    }
    for (int t = 16; t < 64; t++) {
      final int x = w[t - 15];
      final int y = w[t - 2];
      final int s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final int s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & _mask;
    }
    int a = h[0];
    int b = h[1];
    int c = h[2];
    int d = h[3];
    int e = h[4];
    int f = h[5];
    int g = h[6];
    int k = h[7];
    for (int t = 0; t < 64; t++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & _mask) & g);
      final int t1 = (k + s1 + ch + _k[t] + w[t]) & _mask;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & _mask;
      k = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    h[0] = (h[0] + a) & _mask;
    h[1] = (h[1] + b) & _mask;
    h[2] = (h[2] + c) & _mask;
    h[3] = (h[3] + d) & _mask;
    h[4] = (h[4] + e) & _mask;
    h[5] = (h[5] + f) & _mask;
    h[6] = (h[6] + g) & _mask;
    h[7] = (h[7] + k) & _mask;
  }
  return h.map((int v) => v.toRadixString(16).padLeft(8, '0')).join();
}
