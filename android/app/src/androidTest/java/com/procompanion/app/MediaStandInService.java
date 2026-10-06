package com.procompanion.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.IBinder;

/**
 * Another app holding an active media session that is playing, standing in for race-timer's cues
 * (#19 criterion 4). It plays silence on the alarm usage, as race-timer's phone cues play on
 * USAGE_ALARM, and its session is the one the system hands an unclaimed volume key: so off the
 * finish screen a press lowers the alarm stream, which is the test's control.
 *
 * <p>Lives in the test APK, so it runs in that package's own process and uid. Java, not Kotlin:
 * the test APK leaves out the Kotlin standard library, which the app already carries, so a Kotlin
 * class run in this process fails on {@code kotlin.jvm.internal.Intrinsics} (measured). Started
 * and stopped from the shell; see VolumeKeyFinishTest.
 */
public class MediaStandInService extends Service {
    public static final String TAG = "race-timer stand-in";
    private static final String CHANNEL = "stand-in";
    private static final int SAMPLE_RATE = 48_000;

    private MediaSession session;
    private AudioTrack track;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(
                new NotificationChannel(CHANNEL, "Media stand-in", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(TAG)
                .build();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        } else {
            startForeground(1, notification);
        }
        if (track == null) play();
        return START_NOT_STICKY;
    }

    private void play() {
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build();
        track = new AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build())
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(SAMPLE_RATE * 2)
                .build();
        // One second of silence, looped for as long as the service runs.
        track.write(new short[SAMPLE_RATE], 0, SAMPLE_RATE);
        track.setLoopPoints(0, SAMPLE_RATE, -1);
        track.play();

        session = new MediaSession(this, TAG);
        session.setPlaybackToLocal(attributes);
        session.setPlaybackState(new PlaybackState.Builder()
                .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                .setActions(PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_STOP)
                .build());
        session.setActive(true);
    }

    @Override
    public void onDestroy() {
        if (session != null) session.release();
        if (track != null) {
            track.stop();
            track.release();
        }
        super.onDestroy();
    }
}
