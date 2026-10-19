package org.shaolinmobiu;

import android.app.Activity;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;

import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;

/**
 * Read-only validation of a game source selected through Android's document picker.
 * The original file never leaves the device and is not modified or uploaded.
 * An authentic standalone XBE can be identified before a game runtime is available.
 */
final class GameSourceInspector {
    private static final String EXPECTED_XBE_SHA256 =
        "48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a";
    private static final byte[] XBOX_VOLUME_MAGIC =
        "MICROSOFT*XBOX*MEDIA".getBytes(StandardCharsets.US_ASCII);
    private static final long[] XBOX_PARTITION_OFFSETS = {
        0L, 0x18300000L, 0x0FD90000L, 0x02080000L
    };
    private static final int XBOX_SECTOR_SIZE = 2048;
    private static final int MAX_XBE_SIZE = 64 * 1024 * 1024;

    interface Callback {
        void complete(String result);
    }

    private GameSourceInspector() {}

    static void inspect(Activity activity, Uri uri, String fileName, String kind, Callback callback) {
        Handler ui = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            String result;
            try {
                if ("folder".equals(kind)) {
                    result = "✓ Pasta selecionada. A verificação dos arquivos internos será integrada ao runtime Xbox.";
                } else {
                    result = inspectFile(activity, uri, fileName);
                }
            } catch (Exception e) {
                result = "⚠ Não foi possível ler esta fonte: " + e.getClass().getSimpleName();
            }
            final String ready = result;
            ui.post(() -> callback.complete(ready));
        }, "ShaolinSourceInspect").start();
    }

    private static String inspectFile(Activity activity, Uri uri, String name) throws Exception {
        if (name == null) return "⚠ O arquivo selecionado não tem nome.";
        String lower = name.toLowerCase(Locale.ROOT);
        try (ParcelFileDescriptor pfd = activity.getContentResolver().openFileDescriptor(uri, "r")) {
            if (pfd == null) return "⚠ Não foi possível abrir o arquivo selecionado.";
            try (FileInputStream input = new FileInputStream(pfd.getFileDescriptor())) {
                if (lower.endsWith(".xbe")) return inspectXbe(input);
                if (lower.endsWith(".iso") || lower.endsWith(".xiso")) return inspectIso(input);
                if (lower.endsWith(".zip")) return inspectZip(input);
            }
        }
        return "⚠ Formato não reconhecido.";
    }

    private static String inspectXbe(FileInputStream input) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[1024 * 1024];
        long size = 0;
        int n;
        boolean first = true;
        while ((n = input.read(buffer)) >= 0) {
            if (n == 0) continue;
            if (first) {
                first = false;
                if (n < 4 || buffer[0] != 'X' || buffer[1] != 'B' ||
                    buffer[2] != 'E' || buffer[3] != 'H') {
                    return "✕ O arquivo não contém um executável Xbox válido (XBEH).";
                }
            }
            size += n;
            if (size > MAX_XBE_SIZE) return "✕ O default.xbe supera 64 MiB e não é suportado.";
            digest.update(buffer, 0, n);
        }
        StringBuilder hash = new StringBuilder(64);
        for (byte b : digest.digest()) hash.append(String.format(Locale.ROOT, "%02x", b & 255));
        if (EXPECTED_XBE_SHA256.equals(hash.toString())) {
            return "✓ XBE autêntico do Shaolin Monks USA/Europe. SHA-256 confirmado (" +
                (size / 1024) + " KiB). Pronto para a futura integração do jogo.";
        }
        return "✕ XBE diferente do Shaolin Monks suportado pelo recompiler. SHA-256: " +
            hash.substring(0, 16) + "…";
    }

    private static boolean readMagic(FileChannel channel, long absolute, byte[] expected) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(expected.length);
        int got = 0;
        while (b.hasRemaining()) {
            int n = channel.read(b, absolute + got);
            if (n <= 0) return false;
            got += n;
        }
        byte[] actual = b.array();
        return MessageDigest.isEqual(actual, expected);
    }

    private static String inspectIso(FileInputStream input) {
        FileChannel channel = input.getChannel();
        try {
            for (long offset : XBOX_PARTITION_OFFSETS) {
                if (readMagic(channel, offset + 32L * XBOX_SECTOR_SIZE, XBOX_VOLUME_MAGIC)) {
                    return "✓ Volume XDVDFS de Xbox detectado. " +
                        "Ainda é preciso conferir o default.xbe e os arquivos de Shaolin Monks.";
                }
            }
            return "✕ Não foi encontrado o volume XDVDFS nas posições Xbox conhecidas.";
        } catch (IOException e) {
            return "⚠ Fonte sem acesso aleatório. ISO selecionada, mas a validação XDVDFS " +
                "depende de leitura posicionada; nenhum arquivo foi alterado.";
        }
    }

    private static String inspectZip(FileInputStream input) throws IOException {
        byte[] signature = new byte[4];
        if (input.read(signature) != 4) return "✕ Arquivo ZIP incompleto.";
        boolean zip = signature[0] == 'P' && signature[1] == 'K' &&
            ((signature[2] == 3 && signature[3] == 4) ||
             (signature[2] == 5 && signature[3] == 6) ||
             (signature[2] == 7 && signature[3] == 8));
        return zip ? "✓ Estrutura ZIP reconhecida. Conteúdo do jogo ainda não verificado."
            : "✕ Assinatura ZIP inválida.";
    }
}
