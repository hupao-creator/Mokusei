"""Controlled body output; task completion and usage are not animation inputs."""
import hashlib
import math

RATES = {'sparse': 2, 'sustained': 8, 'burst': 8}
DEFAULT_PACING = 'sparse'
STEPS = (
    'Inspecting launch settings and the selected runtime.',
    'Checking the response handler and its cancellation path.',
    'Comparing observed output with the expected task result.',
    'Preparing the final review notes and verification summary.',
)


def schedule(count, seconds, pacing=DEFAULT_PACING, chunk_bytes=64, message_bytes=512):
    if count not in (5, 10, 20) or pacing not in RATES:
        raise ValueError('unsupported body workload')
    if not 64 <= chunk_bytes <= 4096 or not chunk_bytes <= message_bytes <= 16384 or message_bytes % chunk_bytes:
        raise ValueError('message bytes must be a multiple of chunk bytes (64..4096, message <=16384)')
    if not math.isfinite(seconds) or not 2 <= seconds <= 120:
        raise ValueError('body duration must be 2..120 seconds')
    rate = RATES[pacing]
    events = []
    per_message = message_bytes // chunk_bytes
    for seq in range(int(seconds * rate)):
        at = seq / rate if pacing != 'burst' else (seq // 8) + (seq % 8) / 20
        message, part = divmod(seq, per_message)
        for card in range(1, count + 1):
            # Independent tasks need not flush on the same artificial clock
            # edge. A fixed phase preserves every card's packet/byte budget.
            phase = (card - 1) / (count * rate)
            prefix = f'CHECK {card:02d}.{message + 1:04d} ' if part == 0 else f'\nReview note {part + 1}: '
            text = prefix + STEPS[message % len(STEPS)]
            text = (text + ' Confirming the expected behavior.' * chunk_bytes)[:chunk_bytes]
            events.append({'card': card, 'sequence': seq + 1, 'message': message + 1,
                           'part': part, 'atSeconds': at + phase, 'text': text,
                           'bytes': len(text.encode()), 'sha256': hashlib.sha256(text.encode()).hexdigest()})
    notes=[]
    for card in range(1,count+1):
        card_events=[e for e in events if e['card']==card]
        for message in sorted({e['message'] for e in card_events}):
            parts=[e for e in card_events if e['message']==message]
            text=f'CHECK {card:02d}.{message:04d} Progress update: '+STEPS[(message-1)%len(STEPS)]
            notes.append({'card':card,'message':message,'kind':'progress-note','atSeconds':parts[-1]['atSeconds'],
                          'text':text,'bytes':len(text.encode()),'sha256':hashlib.sha256(text.encode()).hexdigest()})
    return {'scheduleVersion':2,'loadKind':'low-rate' if pacing=='sparse' else 'stress',
            'cardTiming':'staggered-within-packet-interval',
            'notes':notes,'pacing': pacing, 'packetsPerSecondPerCard': rate, 'chunkBytes': chunk_bytes,
            'messageBytes': message_bytes, 'burstPacketsPerSecond': 20 if pacing == 'burst' else None,
            'messageIntervalSeconds': per_message / rate, 'durationSeconds': seconds,
            'events': events}
