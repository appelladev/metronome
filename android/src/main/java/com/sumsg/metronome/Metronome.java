package com.sumsg.metronome;

import static android.media.AudioTrack.PLAYSTATE_PLAYING;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Build;

import android.media.AudioAttributes;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicBoolean;
import android.os.Handler;
import android.os.Looper;
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
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object beatLock = new Object();
    private final ArrayDeque<BeatEvent> beatQueue = new ArrayDeque<>();
    private long framesWritten = 0;
    private Thread tickThread;

    private static final class BeatEvent {
        final long frameTime;
        final int tick;

        BeatEvent(long frameTime, int tick) {
            this.frameTime = frameTime;
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
            synchronized (beatLock) {
                beatQueue.clear();
            }
            isRunning.set(true);
            audioTrack.play();
            startTickThreadIfNeeded();
            startMetronome();
        }
    }

    public void pause() {
        isRunning.set(false);
        audioTrack.pause();
        audioTrack.flush();
        scheduleTick = 0;
        framesWritten = 0;
        synchronized (beatLock) {
            beatQueue.clear();
        }
    }

    public void stop() {
        isRunning.set(false);
        audioTrack.flush();
        audioTrack.stop();
        scheduleTick = 0;
        framesWritten = 0;
        synchronized (beatLock) {
            beatQueue.clear();
        }
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

    private void emitTickOnMain(int tick) {
        if (eventTickSink == null) {
            return;
        }
        mainHandler.post(() -> {
            try {
                eventTickSink.success(tick);
            } catch (Exception ignored) {
                // Avoid crashing audio thread on event channel errors.
            }
        });
    }

    private void startTickThreadIfNeeded() {
        if (eventTickSink == null || !isRunning.get() || tickThread != null) {
            return;
        }
        tickThread = new Thread(() -> {
            while (isRunning.get()) {
                long playbackFrames = audioTrack.getPlaybackHeadPosition() & 0xffffffffL;
                drainBeatQueue(playbackFrames);
                try {
                    Thread.sleep(5);
                } catch (InterruptedException ignored) {
                }
            }
            tickThread = null;
        });
        tickThread.start();
    }

    private void drainBeatQueue(long playbackFrames) {
        while (true) {
            BeatEvent event;
            synchronized (beatLock) {
                event = beatQueue.peek();
                if (event == null || event.frameTime > playbackFrames) {
                    return;
                }
                beatQueue.poll();
            }
            emitTickOnMain(event.tick);
        }
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
                    long playbackFrames = audioTrack.getPlaybackHeadPosition() & 0xffffffffL;
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
                    boolean enqueued = false;
                    int offset = 0;
                    while (offset < buffer.length && isRunning.get()) {
                        int written = audioTrack.write(buffer, offset, buffer.length - offset);
                        if (written <= 0) {
                            break;
                        }
                        if (!enqueued && eventTickSink != null) {
                            synchronized (beatLock) {
                                beatQueue.add(new BeatEvent(beatStartFrame, tickToPlay));
                            }
                            enqueued = true;
                        }
                        offset += written;
                        framesWritten += written;
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
