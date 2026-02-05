package com.sumsg.metronome;

import static android.media.AudioTrack.PLAYSTATE_PLAYING;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Build;

import android.media.AudioAttributes;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
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
    private int currentTick = 0;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

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
            currentTick = 0;
            isRunning.set(true);
            audioTrack.play();
            startMetronome();
        }
    }

    public void pause() {
        isRunning.set(false);
        audioTrack.pause();
    }

    public void stop() {
        isRunning.set(false);
        audioTrack.flush();
        audioTrack.stop();
        currentTick = 0;
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

    private void startMetronome() {
        new Thread(() -> {
            while (isRunning.get()) {
                synchronized (mLock) {
                    if (!isPlaying()) {
                        try {
                            Thread.sleep(1);
                        } catch (InterruptedException ignored) {
                        }
                        continue;
                    }
                    int nextBpm = pendingBpm.getAndSet(0);
                    if (nextBpm > 0 && nextBpm != audioBpm) {
                        audioBpm = nextBpm;
                    }
                    int tickToPlay = (audioTimeSignature < 2) ? 0 : currentTick;
                    short[] buffer = generateBeatBuffer(tickToPlay);
                    if (eventTickSink != null) {
                        mainHandler.post(() -> {
                            try {
                                eventTickSink.success(tickToPlay);
                            } catch (Exception ignored) {
                                // Avoid crashing audio thread on event channel errors.
                            }
                        });
                    }
                    audioTrack.write(buffer, 0, buffer.length);
                    if (audioTimeSignature < 2) {
                        currentTick = 0;
                    } else {
                        currentTick = (currentTick + 1) % audioTimeSignature;
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
