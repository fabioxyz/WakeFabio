"""Generate WakeFabio's original alarm tones; no third-party recordings."""
from pathlib import Path
import math
import struct
import wave

destination = Path(__file__).resolve().parents[1] / 'WakeFabio/Resources/OriginalSounds'
destination.mkdir(parents=True, exist_ok=True)
rate = 22050
duration = 3
for name in ('beep', 'chime', 'siren'):
    frames = bytearray()
    for index in range(rate * duration):
        time = index / rate
        if name == 'beep':
            local = time % 0.5
            envelope = min(1, local / 0.01, max(0, (0.24-local)/0.02))
            sample = math.sin(2*math.pi*880*time) * envelope
        elif name == 'chime':
            local = time % 0.75
            frequency = (523.25, 659.25, 783.99, 1046.5)[int(time/0.75) % 4]
            envelope = min(1, local/0.01) * math.exp(-4*local)
            sample = (math.sin(2*math.pi*frequency*local) + 0.2*math.sin(4*math.pi*frequency*local))/1.2*envelope
        else:
            # Continuous phase for a smooth alternating siren.
            phase = 2*math.pi*700*time - 200*math.cos(2*math.pi*time)
            sample = math.sin(phase)
        fade = min(1, time/0.015, (duration-time)/0.025)
        frames.extend(struct.pack('<h', round(0.6*32767*sample*fade)))
    with wave.open(str(destination/f'wake_{name}.wav'), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(frames)
    print(f'Generated wake_{name}.wav')
