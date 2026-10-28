import glob, pathlib, re, shutil

root = pathlib.Path('android')

# ---- AndroidManifest ----
mf = root / 'app/src/main/AndroidManifest.xml'
s = mf.read_text()
perms = '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
    '''
svc = '''<service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>
    '''
s = s.replace('<application', perms + '<application', 1)
s = s.replace('</application>', svc + '</application>', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="静心音乐"', s, count=1)
mf.write_text(s)

# ---- Gradle ----
kts = root / 'app/build.gradle.kts'
groovy = root / 'app/build.gradle'
if kts.exists():
    g = kts.read_text()
    g = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', g)
    g += '''
android {
    packaging { jniLibs { useLegacyPackaging = true } }
}
dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.17.2")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.17.2")
}
'''
    kts.write_text(g)
else:
    g = groovy.read_text()
    g = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', g)
    g += '''
android {
    packagingOptions { jniLibs { useLegacyPackaging = true } }
}
dependencies {
    implementation 'io.github.junkfood02.youtubedl-android:library:0.17.2'
    implementation 'io.github.junkfood02.youtubedl-android:ffmpeg:0.17.2'
}
'''
    groovy.write_text(g)

# ---- MainActivity ----
for p in glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True):
    shutil.copy('native/MainActivity.kt', p)
print('patched')
