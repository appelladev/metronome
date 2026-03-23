package com.sumsg.metronome;

import static android.media.AudioTrack.PLAYSTATE_PLAYING;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.AudioTimestamp;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import android.media.AudioAttributes;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicBoolean;
import io.flutter.plugin.common.EventChannel;

public class Metronome {
    private final Object mLock = new Object();
    private final AudioTrack audioTrack;
    private short[] mainSound;
    private short[] accentedSound;
    private final int SAMPLE_RATE;
    public int audioBpm;
    public int audioTimeSignature;
    public float audioVolume;
    private final AtomicInteger pendingBpm = new AtomicInteger(0);
    private final AtomicBoolean isRunning = new AtomicBoolean(false);
    private EventChannel.EventSink eventTickSink;
    private int scheduleTick = 0;
    private final AudioTimestamp audioTimestamp = new AudioTimestamp();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object beatQueueLock = new Object();
    private final Deque<BeatEvent> beatQueue = new ArrayDeque<>();
    private long framesWritten = 0;
    private long lastPlaybackFrames = 0;
    private volatile boolean hasPlaybackProgress = false;
    private Thread tickThread;

    private static final class BeatEvent {
        private final long framePosition;
        private final long beatDurationFrames;
        private final int tick;

        private BeatEvent(long framePosition, long beatDurationFrames, int tick) {
            this.framePosition = framePosition;
            this.beatDurationFrames = beatDurationFrames;
            this.tick = tick;
        }
    }

    @SuppressWarnings("deprecation")
    public Metronome(byte[] mainFileBytes, byte[] accentedFileBytes, int bpm, int timeSignature, float volume,
            int sampleRate) {
        SAMPLE_RATE = sampleRate;
        audioBpm = bpm;
        audioVolume = volume;
        audioTimeSignature = timeSignature;
        mainSound = byteArrayToShortArray(mainFileBytes);
        if (accentedFileBytes.length == 0) {
            accentedSound = mainSound;
        } else {
            accentedSound = byteArrayToShortArray(accentedFileBytes);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioFormat audioFormat = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build();
            AudioAttributes audioAttributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build();
            audioTrack = new AudioTrack.Builder()
                    .setAudioAttributes(audioAttributes)
                    .setAudioFormat(audioFormat)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    // .setBufferSizeInBytes(SAMPLE_RATE)
                    // .setBufferSizeInBytes(SAMPLE_RATE * 2)
                    .build();
        } else {
            audioTrack = new AudioTrack(AudioManager.STREAM_MUSIC, SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, SAMPLE_RATE, AudioTrack.MODE_STREAM);
        }
        setVolume(volume);
    }

    public void play() {
        if (!isRunning.get()) {
            scheduleTick = 0;
            framesWritten = 0;
            lastPlaybackFrames = 0;
            hasPlaybackProgress = false;
            clearBeatQueue();
            isRunning.set(true);
            audioTrack.play();
            startMetronome();
            startTickThreadIfNeeded();
        }
    }

    public void pause() {
        isRunning.set(false);
        audioTrack.pause();
        audioTrack.flush();
        scheduleTick = 0;
        framesWritten = 0;
        lastPlaybackFrames = 0;
        hasPlaybackProgress = false;
        stopTickThread();
        clearBeatQueue();
    }

    public void stop() {
        isRunning.set(false);
        audioTrack.flush();
        audioTrack.stop();
        scheduleTick = 0;
        framesWritten = 0;
        lastPlaybackFrames = 0;
        hasPlaybackProgress = false;
        stopTickThread();
        clearBeatQueue();
    }

    public void setBPM(int bpm) {
        if (bpm != audioBpm) {
            if (isPlaying()) {
                pendingBpm.set(bpm);
            } else {
                audioBpm = bpm;
            }
        }
    }

    public void setTimeSignature(int timeSignature) {
        if (timeSignature != audioTimeSignature) {
            audioTimeSignature = timeSignature;
            if (isPlaying()) {
                pause();
                play();
            }
        }
    }

    public void setAudioFile(byte[] mainFileBytes, byte[] accentedFileBytes) {
        if (mainFileBytes.length > 0) {
            mainSound = byteArrayToShortArray(mainFileBytes);
        }
        if (accentedFileBytes.length > 0) {
            accentedSound = byteArrayToShortArray(accentedFileBytes);
        }
        if (mainFileBytes.length > 0 || accentedFileBytes.length > 0) {
            if (isPlaying()) {
                pause();
                play();
            }
        }
    }

    @SuppressWarnings("deprecation")
    public void setVolume(float volume) {
        audioVolume = volume;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            audioTrack.setVolume(volume);
        } else {
            audioTrack.setStereoVolume(volume, volume);
        }
    }

    public boolean isPlaying() {
        return audioTrack.getPlayState() == PLAYSTATE_PLAYING;
    }

    public void enableTickCallback(EventChannel.EventSink _eventTickSink) {
        eventTickSink = _eventTickSink;
        startTickThreadIfNeeded();
    }

    private short[] byteArrayToShortArray(byte[] byteArray) {
        if (byteArray == null || byteArray.length % 2 != 0) {
            throw new IllegalArgumentException("Invalid byte array length for PCM_16BIT");
        }
        short[] shortArray = new short[byteArray.length / 2];
        ByteBuffer.wrap(byteArray).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(shortArray);
        return shortArray;
    }

    private short[] generateBeatBuffer(int tick) {
        int framesPerBeat = (int) (SAMPLE_RATE * 60 / (float) audioBpm);
        short[] buffer = new short[framesPerBeat];
        short[] sound = (audioTimeSignature >= 2 && tick == 0) ? accentedSound : mainSound;
        int soundLength = Math.min(framesPerBeat, sound.length);
        System.arraycopy(sound, 0, buffer, 0, soundLength);
        return buffer;
    }

    private long framesToMicros(long frames) {
        return (frames * 1_000_000L) / SAMPLE_RATE;
    }

    private void emitTick(BeatEvent beatEvent, long playbackFrames) {
        if (eventTickSink == null) {
            return;
        }
        long elapsedFrames = Math.max(0L, playbackFrames - beatEvent.framePosition);
        long beatDurationMicros = Math.max(0L, framesToMicros(beatEvent.beatDurationFrames));
        long elapsedMicros = Math.min(
                beatDurationMicros,
                Math.max(0L, framesToMicros(elapsedFrames))
        );
        Map<String, Object> payload = new HashMap<>();
        payload.put("tick", beatEvent.tick);
        payload.put("beatDurationMicros", beatDurationMicros);
        payload.put("elapsedSinceBeatStartMicros", elapsedMicros);
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                eventTickSink.success(payload);
            } catch (Exception ignored) {
                // Avoid crashing tick thread on event channel errors.
            }
            return;
        }
        mainHandler.post(() -> {
            try {
                eventTickSink.success(payload);
            } catch (Exception ignored) {
                // Avoid crashing tick thread on event channel errors.
            }
        });
    }

    private void clearBeatQueue() {
        synchronized (beatQueueLock) {
            beatQueue.clear();
        }
    }

    private void enqueueBeat(long beatStartFrame, long beatDurationFrames, int tick) {
        synchronized (beatQueueLock) {
            beatQueue.addLast(new BeatEvent(beatStartFrame, beatDurationFrames, tick));
        }
    }

    private void discardQueuedBeat(long beatStartFrame, int tick) {
        synchronized (beatQueueLock) {
            BeatEvent last = beatQueue.peekLast();
            if (last != null && last.framePosition == beatStartFrame && last.tick == tick) {
                beatQueue.removeLast();
            }
        }
    }

    private void stopTickThread() {
        if (tickThread != null) {
            tickThread.interrupt();
            tickThread = null;
        }
    }

    private void startTickThreadIfNeeded() {
        if (!isRunning.get() || tickThread != null) {
            return;
        }
        tickThread = new Thread(() -> {
            while (isRunning.get()) {
                long playbackFrames = getPlaybackFrames();
                if (!hasPlaybackProgress) {
                    // Match Darwin semantics by waiting for real AudioTrack progress
                    // before emitting the first queued beat at frame 0.
                    if (playbackFrames <= 0) {
                        try {
                            Thread.sleep(1);
                        } catch (InterruptedException ignored) {
                            Thread.currentThread().interrupt();
                            break;
                        }
                        continue;
                    }
                    hasPlaybackProgress = true;
                }
                List<BeatEvent> dueEvents = new ArrayList<>();
                synchronized (beatQueueLock) {
                    while (!beatQueue.isEmpty() && beatQueue.peekFirst().framePosition <= playbackFrames) {
                        dueEvents.add(beatQueue.removeFirst());
                    }
                }
                for (BeatEvent event : dueEvents) {
                    emitTick(event, playbackFrames);
                }
                try {
                    Thread.sleep(5);
                } catch (InterruptedException ignored) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
            tickThread = null;
        });
        tickThread.start();
    }

    private long getPlaybackFrames() {
        long head = audioTrack.getPlaybackHeadPosition() & 0xffffffffL;
        long estimate = head;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            if (audioTrack.getTimestamp(audioTimestamp)) {
                long now = System.nanoTime();
                long nanosSince = now - audioTimestamp.nanoTime;
                long framesSince = (nanosSince * SAMPLE_RATE) / 1_000_000_000L;
                estimate = audioTimestamp.framePosition + framesSince;
            }
        }
        long current = Math.max(head, estimate);
        if (current < 0) {
            current = 0;
        }
        if (current < lastPlaybackFrames) {
            current = lastPlaybackFrames;
        }
        lastPlaybackFrames = current;
        return current;
    }

    private void startMetronome() {
        new Thread(() -> {
            while (isRunning.get()) {
                synchronized (mLock) {
                    int nextBpm = pendingBpm.getAndSet(0);
                    if (nextBpm > 0 && nextBpm != audioBpm) {
                        audioBpm = nextBpm;
                    }
                    int framesPerBeat = (int) (SAMPLE_RATE * 60 / (float) audioBpm);
                    if (framesPerBeat <= 0) {
                        continue;
                    }
                    long playbackFrames = getPlaybackFrames();
                    long framesInBuffer = framesWritten - playbackFrames;
                    if (framesInBuffer < 0) {
                        framesInBuffer = 0;
                    }
                    if (framesInBuffer >= framesPerBeat) {
                        try {
                            Thread.sleep(1);
                        } catch (InterruptedException ignored) {
                        }
                        continue;
                    }
                    int tickToPlay = (audioTimeSignature < 2) ? 0 : scheduleTick;
                    short[] buffer = generateBeatBuffer(tickToPlay);
                    long beatStartFrame = framesWritten;
                    // Queue the beat boundary before a blocking write so the next
                    // tick is not delayed until the write call returns.
                    enqueueBeat(beatStartFrame, framesPerBeat, tickToPlay);
                    int offset = 0;
                    while (offset < buffer.length && isRunning.get()) {
                        int written = audioTrack.write(buffer, offset, buffer.length - offset);
                        if (written <= 0) {
                            break;
                        }
                        offset += written;
                        framesWritten += written;
                    }
                    if (offset != buffer.length) {
                        discardQueuedBeat(beatStartFrame, tickToPlay);
                        continue;
                    }
                    if (audioTimeSignature < 2) {
                        scheduleTick = 0;
                    } else {
                        scheduleTick = (scheduleTick + 1) % audioTimeSignature;
                    }
                }
            }
        }).start();
    }

    public void destroy() {
        stop();
        audioTrack.release();
    }
}
