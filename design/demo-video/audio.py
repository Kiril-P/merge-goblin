# Soundtrack for the Merge Goblin brag video: 96 BPM, A minor, 8 bars = 20.0 s.
# Music and effects share one key and one reverb so they sit together.
import numpy as np, wave

SR = 48000
DUR = 20.0
N = int(SR * DUR)
BEAT = 60 / 96
BAR = BEAT * 4
rng = np.random.default_rng(7)

def hz(m): return 440.0 * 2 ** ((m - 69) / 12)
def t_(d): return np.arange(int(SR * d)) / SR

L = np.zeros(N); R = np.zeros(N)
def add(buf, x, at, gain=1.0):
    i = int(at * SR)
    if i >= N: return
    x = x[: N - i]
    buf[i:i + len(x)] += x * gain
def add2(x, at, g=1.0, pan=0.0):
    add(L, x, at, g * (1 - max(0, pan))); add(R, x, at, g * (1 + min(0, pan)))

def lowpass(x, cut):
    a = np.exp(-2 * np.pi * cut / SR); y = np.empty_like(x); s = 0.0
    for i in range(len(x)):
        s = (1 - a) * x[i] + a * s; y[i] = s
    return y
def lp_fast(x, cut, passes=2):
    # one-pole lowpass applied with a vectorised IIR via lfilter-free trick (cumulative)
    a = np.exp(-2 * np.pi * cut / SR)
    for _ in range(passes):
        y = np.empty_like(x); s = 0.0
        # chunked python loop is too slow for long buffers; use scipy-free recursion in blocks
        b = 1 - a
        for i in range(len(x)):
            s = b * x[i] + a * s; y[i] = s
        x = y
    return x
def saw(f, d, det=0.0):
    tt = t_(d); ph = (f * (1 + det)) * tt
    return 2 * (ph - np.floor(ph + 0.5))
def env(d, a, r, sus=1.0):
    n = int(SR * d); e = np.ones(n) * sus
    na = max(1, int(SR * a)); e[:na] = np.linspace(0, 1, na) * sus
    nr = min(n, int(SR * r)); e[n - nr:] *= np.linspace(1, 0, nr)
    return e
def pluck(f, d, dec, kind="tri"):
    tt = t_(d)
    if kind == "tri": w = 2 * np.abs(2 * ((f * tt) % 1) - 1) - 1
    else: w = np.sin(2 * np.pi * f * tt)
    return w * np.exp(-tt / dec) * np.minimum(1, tt / 0.004)

# A minor: Am F C G | Am F G Am
CH = {"Am": [57, 60, 64], "F": [53, 57, 60], "C": [55, 60, 64], "G": [55, 59, 62]}
ROOT = {"Am": 45, "F": 41, "C": 48, "G": 43}
prog = ["Am", "F", "C", "G", "Am", "F", "G", "Am"]

# --- pad (detuned saws, soft, wide) ---
pad_l = np.zeros(N); pad_r = np.zeros(N)
for b, c in enumerate(prog):
    at = b * BAR; d = BAR + 0.6 if b < 7 else DUR - at
    for m in CH[c]:
        f = hz(m)
        e = env(d, 0.35, 0.6)
        add(pad_l, (saw(f, d, -0.004) + saw(f, d, 0.003)) * e, at, 0.05)
        add(pad_r, (saw(f, d, 0.004) + saw(f, d, -0.002)) * e, at, 0.05)
# cheap lowpass via FFT (brickwall-ish with soft rolloff)
def fft_lp(x, cut):
    X = np.fft.rfft(x); fr = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / (1 + (fr / cut) ** 4); return np.fft.irfft(X, len(x))
def fft_hp(x, cut):
    X = np.fft.rfft(x); fr = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / (1 + (cut / np.maximum(fr, 1)) ** 4); return np.fft.irfft(X, len(x))
L += fft_lp(pad_l, 1400); R += fft_lp(pad_r, 1400)

# --- arp: eighth notes over chord tones, octave up ---
step = BEAT / 2
pattern = [0, 1, 2, 1, 2, 0, 1, 2]
for b, c in enumerate(prog):
    tones = [m + 12 for m in CH[c]] + [CH[c][0] + 24]
    for k in range(8):
        at = b * BAR + k * step
        if at > 19.2: break
        m = tones[pattern[k] if k != 6 else 3]
        g = 0.10 if at < 2.5 else 0.10
        if at > 17.5: g *= max(0.0, 1 - (at - 17.5) / 2.0)
        add2(pluck(hz(m), 0.5, 0.16), at, g, pan=0.25 if k % 2 else -0.25)

# --- drums + bass from bar 2 until the outro ---
def kick():
    tt = t_(0.35); f = 45 + 80 * np.exp(-tt / 0.035)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / 0.16)
def hat():
    x = rng.standard_normal(int(SR * 0.05)); x = np.diff(np.concatenate([[0], x]))
    return x * np.exp(-t_(0.05) / 0.012)
def snare():
    tt = t_(0.25); n = rng.standard_normal(len(tt))
    return (fft_hp(n, 1500) * 0.6 + np.sin(2 * np.pi * 190 * tt) * 0.4) * np.exp(-tt / 0.07)
K, H, S = kick(), hat(), snare()
for b in range(1, 7):
    for beat in range(4):
        at = b * BAR + beat * BEAT
        add2(K, at, 0.26 if beat in (0, 2) else 0.12)
        add2(H, at + BEAT / 2, 0.05, pan=0.3)
        if b >= 2 and beat in (1, 3): add2(fft_lp(S, 6000), at, 0.045)
    c = prog[b]
    for k in range(8):
        at = b * BAR + k * step
        tt = t_(step * 0.9); f = hz(ROOT[c])
        x = np.tanh(1.6 * np.sin(2 * np.pi * f * tt)) * np.exp(-tt / 0.22) * np.minimum(1, tt / 0.005)
        add2(x, at, 0.12 if k % 2 == 0 else 0.07)
# final low A under the outro
tt = t_(DUR - 7 * BAR); add2(np.sin(2 * np.pi * hz(33) * tt) * env(DUR - 7 * BAR, 0.05, 1.5), 7 * BAR, 0.10)

# --- effects, in A minor ---
def tick(g=1.0):
    x = fft_hp(rng.standard_normal(int(SR * 0.03)), 3000) * np.exp(-t_(0.03) / 0.006); return x * g
def click():
    p = pluck(hz(81), 0.08, 0.02, "sine") * 0.4; k = tick(1.0) * 1.2; p[:len(k)] += k; return p
def whoosh(d=0.5):
    n = rng.standard_normal(int(SR * d)); x = fft_lp(fft_hp(n, 400), 3500)
    e = np.sin(np.pi * np.linspace(0, 1, len(x))) ** 2; return x * e
def bell(m, d=1.2, dec=0.45):
    tt = t_(d); f = hz(m)
    return (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 2.01 * f * tt)) * np.exp(-tt / dec) * np.minimum(1, tt / 0.003)
def thunk():
    tt = t_(0.6); f = 55 + 60 * np.exp(-tt / 0.06)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt / 0.25)

for i in range(18): add2(tick(), 0.25 + i * (0.8 / 18), 0.05, pan=0.1)   # typing on the button
add2(click(), 1.9, 0.16)                                                 # the click
add2(thunk(), 2.05, 0.36)                                                 # refused
add2(pluck(hz(64), 0.4, 0.12, "sine"), 2.08, 0.10); add2(pluck(hz(57), 0.6, 0.2, "sine"), 2.24, 0.10)
add2(whoosh(0.5), 3.15, 0.05)
add2(click(), 3.95, 0.12)                                                # menu bar icon
add2(bell(81, 0.5, 0.12), 4.05, 0.06)                                    # popover opens
for i, at in enumerate([7.6, 7.69, 7.78]): add2(click(), at, 0.09)       # ⌥⌘G
for i in range(4): add2(tick(), 7.95 + i * 0.125, 0.07)                  # 2456
add2(click(), 8.6, 0.13)                                                 # Review
add2(bell(76, 0.6, 0.15), 9.55, 0.035); add2(bell(79, 0.6, 0.15), 10.35, 0.035)
add2(bell(81, 1.4, 0.5), 11.25, 0.07); add2(bell(88, 1.4, 0.5), 11.32, 0.05)   # ready to read
add2(whoosh(0.45), 11.95, 0.045)
add2(whoosh(0.4), 14.0, 0.035)
add2(whoosh(0.5), 16.35, 0.045)
for i, m in enumerate([69, 72, 76, 81]): add2(bell(m, 1.8, 0.7), 16.8 + i * 0.09, 0.045)

# --- mix: shared room, gentle glue, master fade ---
def reverb(x):
    ir = rng.standard_normal(int(SR * 1.6)) * np.exp(-t_(1.6) / 0.38)
    ir = fft_lp(ir, 5000); ir /= np.sqrt(np.sum(ir ** 2))
    n = len(x) + len(ir); X = np.fft.rfft(x, n) * np.fft.rfft(ir, n)
    return np.fft.irfft(X, n)[: len(x)]
L = L + 0.22 * reverb(L); R = R + 0.22 * reverb(R)
for buf in (L, R):
    buf[:] = np.tanh(buf * 1.25) / 1.25
fade = np.ones(N); nf = int(SR * 0.9); fade[-nf:] = np.linspace(1, 0, nf) ** 1.5
fi = int(SR * 0.04); fade[:fi] = np.linspace(0, 1, fi)
L *= fade; R *= fade
peak = max(np.abs(L).max(), np.abs(R).max()); L *= 0.89 / peak; R *= 0.89 / peak
st = (np.stack([L, R], 1) * 32767).astype(np.int16)
with wave.open("music.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(st.tobytes())
print("wrote music.wav", DUR, "s")
