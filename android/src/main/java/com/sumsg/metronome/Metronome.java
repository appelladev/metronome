package com.sumsg.metronome;

import static android.media.AudioTrack.PLAYSTATE_PLAYING;

import android.content.Context;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioPlaybackConfiguration;
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
    private static final long AUDIO_FOCUS_RECOVERY_RETRY_DELAY_MS = 1000L;
    private final Object mLock = new Object();
    private final AudioManager audioManager;
    private final AudioAttributes audioAttributes;
    private AudioFocusRequest audioFocusRequest;
    private final AudioTrack audioTrack;
    private short[] mainSound;
    private short[] accentedSound;
    private final int SAMPLE_RATE;
    public int audioBpm;
    public int audioTimeSignature;
    public float audioVolume;
    private final AtomicInteger pendingBpm = new AtomicInteger(0);
    private final AtomicBoolean isRunning = new AtomicBoolean(false);
    private volatile EventChannel.EventSink eventTickSink;
    private AudioManager.AudioPlaybackCallback audioPlaybackCallback;
    private int scheduleTick = 0;
    private final AudioTimestamp audioTimestamp = new AudioTimestamp();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object beatQueueLock = new Object();
    private final Deque<BeatEvent> beatQueue = new ArrayDeque<>();
    private long framesWritten = 0;
    private long lastPlaybackFrames = 0;
    private volatile boolean hasPlaybackProgress = false;
    private volatile boolean shouldResumeAfterAudioFocusGain = false;
    private volatile boolean isMutedByAudioFocus = false;
    private volatile Thread audioThread;
    private volatile Thread tickThread;
    private final Runnable audioFocusRecoveryRunnable = this::resumeWhenAudioFocusIsAvailable;
    private final AudioManager.OnAudioFocusChangeListener audioFocusChangeListener = focusChange -> {
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS) {
            muteForAudioFocusLoss(true);
            waitForExternalPlaybackToStop();
            return;
        }
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            muteForAudioFocusLoss(true);
            return;
        }
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) {
            muteForAudioFocusLoss(true);
            return;
        }
        if (focusChange == AudioManager.AUDIOFOCUS_GAIN) {
            resumeAfterAudioFocusGain();
        }
    };

    private void muteForAudioFocusLoss(boolean shouldRestoreOnGain) {
        boolean wasRunning = isRunning.get();
        shouldResumeAfterAudioFocusGain = shouldRestoreOnGain && wasRunning;
        if (!shouldResumeAfterAudioFocusGain) {
            stopExternalPlaybackRecovery();
            setMutedByAudioFocus(false);
            return;
        }
        setMutedByAudioFocus(true);
    }

    private void resumeAfterAudioFocusGain() {
        stopExternalPlaybackRecovery();
        if (!shouldResumeAfterAudioFocusGain) {
            setMutedByAudioFocus(false);
            return;
        }
        shouldResumeAfterAudioFocusGain = false;
        setMutedByAudioFocus(false);
    }

    private void waitForExternalPlaybackToStop() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || audioManager == null) {
            return;
        }
        if (audioPlaybackCallback == null) {
            audioPlaybackCallback = new AudioManager.AudioPlaybackCallback() {
                @Override
                public void onPlaybackConfigChanged(List<AudioPlaybackConfiguration> configs) {
                    if (!hasActivePlayback(configs)) {
                        mainHandler.post(audioFocusRecoveryRunnable);
                    }
                }
            };
            audioManager.registerAudioPlaybackCallback(audioPlaybackCallback, mainHandler);
        }
        if (!hasActiveExternalPlayback()) {
            mainHandler.post(audioFocusRecoveryRunnable);
        }
    }

    private void resumeWhenAudioFocusIsAvailable() {
        if (!shouldResumeAfterAudioFocusGain || !isMutedByAudioFocus) {
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && hasActiveExternalPlayback()) {
            return;
        }
        if (requestAudioFocus()) {
            resumeAfterAudioFocusGain();
            return;
        }
        mainHandler.postDelayed(
                audioFocusRecoveryRunnable,
                AUDIO_FOCUS_RECOVERY_RETRY_DELAY_MS);
    }

    private boolean hasActiveExternalPlayback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || audioManager == null) {
            return false;
        }
        return hasActivePlayback(audioManager.getActivePlaybackConfigurations());
    }

    private boolean hasActivePlayback(List<AudioPlaybackConfiguration> configs) {
        if (configs == null) {
            return false;
        }
        return configs.size() > 1;
    }

    private void stopExternalPlaybackRecovery() {
        mainHandler.removeCallbacks(audioFocusRecoveryRunnable);
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || audioManager == null || audioPlaybackCallback == null) {
            audioPlaybackCallback = null;
            return;
        }
        audioManager.unregisterAudioPlaybackCallback(audioPlaybackCallback);
        audioPlaybackCallback = null;
    }

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
    public Metronome(Context context, byte[] mainFileBytes, byte[] accentedFileBytes, int bpm, int timeSignature,
            float volume, int sampleRate) {
        SAMPLE_RATE = sampleRate;
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        audioBpm = bpm;
        audioVolume = volume;
        audioTimeSignature = timeSignature;
        mainSound = byteArrayToShortArray(mainFileBytes);
        if (accentedFileBytes.length == 0) {
            accentedSound = mainSound;
        } else {
            accentedSound = byteArrayToShortArray(accentedFileBytes);
        }
        audioAttributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioFormat audioFormat = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
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
            stopExternalPlaybackRecovery();
            shouldResumeAfterAudioFocusGain = false;
            boolean hasAudioFocus = requestAudioFocus();
            scheduleTick = 0;
            framesWritten = 0;
            lastPlaybackFrames = 0;
            hasPlaybackProgress = false;
            clearBeatQueue();
            isRunning.set(true);
            audioTrack.play();
            setMutedByAudioFocus(!hasAudioFocus);
            if (!hasAudioFocus) {
                shouldResumeAfterAudioFocusGain = true;
                waitForExternalPlaybackToStop();
            }
            startMetronome();
            startTickThreadIfNeeded();
        }
    }

    public void pause() {
        stopExternalPlaybackRecovery();
        shouldResumeAfterAudioFocusGain = false;
        isRunning.set(false);
        audioTrack.pause();
        audioTrack.flush();
        scheduleTick = 0;
        framesWritten = 0;
        lastPlaybackFrames = 0;
        hasPlaybackProgress = false;
        stopAudioThread();
        stopTickThread();
        clearBeatQueue();
        abandonAudioFocus();
        setMutedByAudioFocus(false);
    }

    public void stop() {
        stopExternalPlaybackRecovery();
        shouldResumeAfterAudioFocusGain = false;
        isRunning.set(false);
        audioTrack.flush();
        audioTrack.stop();
        scheduleTick = 0;
        framesWritten = 0;
        lastPlaybackFrames = 0;
        hasPlaybackProgress = false;
        stopAudioThread();
        stopTickThread();
        clearBeatQueue();
        abandonAudioFocus();
        setMutedByAudioFocus(false);
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
        applyEffectiveVolume();
    }

    @SuppressWarnings("deprecation")
    private void applyEffectiveVolume() {
        float effectiveVolume = isMutedByAudioFocus ? 0.0f : audioVolume;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            audioTrack.setVolume(effectiveVolume);
        } else {
            audioTrack.setStereoVolume(effectiveVolume, effectiveVolume);
        }
    }

    public boolean isPlaying() {
        return audioTrack.getPlayState() == PLAYSTATE_PLAYING;
    }

    @SuppressWarnings("deprecation")
    private boolean requestAudioFocus() {
        if (audioManager == null) {
            return true;
        }
        final int result;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (audioFocusRequest == null) {
                audioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(audioAttributes)
                        .setOnAudioFocusChangeListener(audioFocusChangeListener, mainHandler)
                        .build();
            }
            result = audioManager.requestAudioFocus(audioFocusRequest);
        } else {
            result = audioManager.requestAudioFocus(
                    audioFocusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN);
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
    }

    @SuppressWarnings("deprecation")
    private void abandonAudioFocus() {
        if (audioManager == null) {
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest(audioFocusRequest);
            }
            return;
        }
        audioManager.abandonAudioFocus(audioFocusChangeListener);
    }

    public void enableTickCallback(EventChannel.EventSink _eventTickSink) {
        eventTickSink = _eventTickSink;
        if (_eventTickSink == null) {
            stopTickThread();
            clearBeatQueue();
            return;
        }
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

    private void setMutedByAudioFocus(boolean isMuted) {
        isMutedByAudioFocus = isMuted;
        applyEffectiveVolume();
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

    private void stopAudioThread() {
        Thread thread = audioThread;
        if (thread == null) {
            return;
        }
        thread.interrupt();
        if (thread != Thread.currentThread()) {
            try {
                thread.join(750);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }
        if (audioThread == thread) {
            audioThread = null;
        }
    }

    private void startTickThreadIfNeeded() {
        if (!isRunning.get() || tickThread != null || eventTickSink == null) {
            return;
        }
        tickThread = new Thread(() -> {
            while (isRunning.get() && eventTickSink != null) {
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
        if (audioThread != null && audioThread.isAlive()) {
            return;
        }
        audioThread = new Thread(() -> {
            try {
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
                                Thread.currentThread().interrupt();
                                break;
                            }
                            continue;
                        }
                        int tickToPlay = (audioTimeSignature < 2) ? 0 : scheduleTick;
                        short[] buffer = generateBeatBuffer(tickToPlay);
                        long beatStartFrame = framesWritten;
                        boolean shouldQueueBeat = eventTickSink != null;
                        // Queue the beat boundary before a blocking write so the next
                        // tick is not delayed until the write call returns.
                        if (shouldQueueBeat) {
                            enqueueBeat(beatStartFrame, framesPerBeat, tickToPlay);
                        }
                        int offset = 0;
                        while (offset < buffer.length && isRunning.get()) {
                            final int written;
                            try {
                                written = audioTrack.write(buffer, offset, buffer.length - offset);
                            } catch (Exception ignored) {
                                isRunning.set(false);
                                break;
                            }
                            if (written <= 0) {
                                break;
                            }
                            offset += written;
                            framesWritten += written;
                        }
                        if (offset != buffer.length) {
                            if (shouldQueueBeat) {
                                discardQueuedBeat(beatStartFrame, tickToPlay);
                            }
                            continue;
                        }
                        if (audioTimeSignature < 2) {
                            scheduleTick = 0;
                        } else {
                            scheduleTick = (scheduleTick + 1) % audioTimeSignature;
                        }
                    }
                }
            } finally {
                if (Thread.currentThread() == audioThread) {
                    audioThread = null;
                }
            }
        });
        audioThread.start();
    }

    public void destroy() {
        stop();
        audioTrack.release();
    }
}
