package kr.macdroid;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * MacDroid 앱 인덱서 — `app_process`로 기기에서 실행된다(adb shell 권한).
 * 폰 런처(앱 서랍)와 같은 목록(ACTION_MAIN + CATEGORY_LAUNCHER)을 실제 라벨·실제 아이콘과 함께 출력한다.
 * 출력: 처리 직전 "BEGIN\t<package>", 완료 시 "APP\t<package>\t<activity>\t<label>\t<base64 PNG>"
 * 인자: <아이콘 크기(px)> [<package>]
 *   두 번째 인자가 있으면 목록에서 그 앱 전까지 건너뛰고, 그 앱은 라벨만(아이콘 생략) 낸 뒤 이어서 처리한다.
 * 일부 앱 아이콘은 그리는 중 네이티브 abort(Samsung: gDefaultTypeface assert)로 프로세스를 죽인다 —
 * Java로 잡을 수 없으므로 호출 측이 마지막 BEGIN 앱을 두 번째 인자로 넘겨 다시 실행한다.
 */
public final class AppIndex {

    public static void main(String[] args) throws Exception {
        int size = args.length > 0 ? Integer.parseInt(args[0]) : 128;
        String resumeAt = args.length > 1 ? args[1] : null;
        boolean skipping = resumeAt != null;
        Looper.prepareMainLooper();
        Context context = systemContext();
        PackageManager pm = context.getPackageManager();

        Intent intent = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> entries = pm.queryIntentActivities(intent, 0);
        PrintStream out = new PrintStream(System.out, false, "UTF-8");
        Set<String> seen = new HashSet<>();
        for (ResolveInfo entry : entries) {
            ActivityInfo activity = entry.activityInfo;
            if (activity == null || !seen.add(activity.packageName)) continue;
            boolean labelOnly = false;
            if (skipping) {
                if (!activity.packageName.equals(resumeAt)) continue;
                skipping = false;
                labelOnly = true;
            }
            out.println("BEGIN\t" + activity.packageName);
            out.flush();
            String label = clean(String.valueOf(entry.loadLabel(pm)));
            String icon = "";
            try {
                if (!labelOnly) icon = encode(entry.loadIcon(pm), size);
            } catch (Throwable ignored) {
                // 아이콘 실패는 치명 아님 — 라벨만 보낸다
            }
            out.println("APP\t" + activity.packageName + "\t" + activity.name + "\t" + label + "\t" + icon);
            out.flush();
        }
        out.flush();
        System.exit(0);
    }

    /** shell uid에서 쓸 수 있는 시스템 Context(scrcpy server와 같은 방식). */
    private static Context systemContext() throws Exception {
        Class<?> threadClass = Class.forName("android.app.ActivityThread");
        Constructor<?> constructor = threadClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object thread = constructor.newInstance();
        Field current = threadClass.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        fillConfigurationController(threadClass, thread);
        Method getSystemContext = threadClass.getDeclaredMethod("getSystemContext");
        return (Context) getSystemContext.invoke(thread);
    }

    /** Samsung CompatSandbox가 getConfiguration()을 부르므로 컨트롤러를 채운다(Android 12+, scrcpy와 같은 우회). */
    private static void fillConfigurationController(Class<?> threadClass, Object thread) {
        try {
            Class<?> controllerClass = Class.forName("android.app.ConfigurationController");
            Class<?> internalClass = Class.forName("android.app.ActivityThreadInternal");
            Constructor<?> constructor = controllerClass.getDeclaredConstructor(internalClass);
            constructor.setAccessible(true);
            Object controller = constructor.newInstance(thread);
            Field field = threadClass.getDeclaredField("mConfigurationController");
            field.setAccessible(true);
            field.set(thread, controller);
        } catch (Throwable ignored) {
            // 구버전(필드 없음)은 필요 없다
        }
    }

    private static String encode(Drawable drawable, int size) {
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, size, size);
        drawable.draw(canvas);
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
        bitmap.recycle();
        return Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
    }

    private static String clean(String text) {
        return text.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ').trim();
    }
}
