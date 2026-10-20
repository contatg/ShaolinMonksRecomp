package org.shaolinmobiu;

import android.content.Context;
import android.net.Uri;

import org.json.JSONArray;
import org.json.JSONObject;
import org.tukaani.xz.XZInputStream;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Sandbox-only Krypt package manager. It parses and validates PC-compatible
 * mod.json and .tar.xz, hashes all payload files, and records desired enabled
 * state, without pretending the not-yet-ported Xbox filesystem uses the mods.
 *
 * Absolutely no arbitrary native code or Lua scripts are executed here.
 */
final class ModStore {
    static final String CATALOG_URL =
        "https://raw.githubusercontent.com/OAleex/ShaolinMonksRecompKrypt/master/mods.json";
    static final String RELEASE_PREFIX =
        "https://github.com/OAleex/ShaolinMonksRecompKrypt/releases/download/";
    static final String GAME_SHA =
        "48240902bf4a04eb89376217c529531032d3370749bcce91a194878cc49db74a";
    private static final long ARCHIVE_LIMIT = 2L * 1024 * 1024 * 1024;
    private static final long TOTAL_LIMIT = 1024L * 1024 * 1024;
    private static final long FILE_LIMIT = 512L * 1024 * 1024;
    private final Context context;
    private final File root;
    private final File packages;
    private final File registry;

    ModStore(Context context) {
        this.context = context.getApplicationContext();
        this.root = new File(context.getFilesDir(), "krypt");
        this.packages = new File(root, "packages");
        this.registry = new File(root, "installed.json");
    }

    static JSONObject downloadCatalog() throws Exception {
        byte[] bytes = fetch(CATALOG_URL, 8L * 1024 * 1024, null, null);
        JSONObject json = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
        int schema = json.getInt("schema");
        if (schema != 1 && schema != 2) throw new IOException("Versão de catálogo incompatível");
        if (!GAME_SHA.equals(json.getJSONObject("game").getString("xbe_sha256")))
            throw new IOException("Catálogo pertence a outra versão do jogo");
        JSONArray rows = json.getJSONArray("mods");
        if (rows.length() > 1000) throw new IOException("Catálogo muito grande");
        return json;
    }

    static byte[] fetch(String url, long limit, String expectedHash, Long expectedLength) throws Exception {
        if (!url.equals(CATALOG_URL) && !url.startsWith(RELEASE_PREFIX))
            throw new IOException("Endereço de download não autorizado");
        URL parsed = new URL(url);
        HttpURLConnection connection = (HttpURLConnection) parsed.openConnection();
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(30000);
        connection.setInstanceFollowRedirects(true);
        connection.setRequestProperty("User-Agent", "ShaolinMobiu-Android/0.1");
        try {
            if (connection.getResponseCode() != 200) throw new IOException("HTTP " + connection.getResponseCode());
            if (!"https".equalsIgnoreCase(connection.getURL().getProtocol()))
                throw new IOException("Redirecionamento inseguro");
            try (InputStream in = connection.getInputStream();
                 ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buf = new byte[65536];
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                long total = 0;
                int n;
                while ((n = in.read(buf)) != -1) {
                    if (n == 0) continue;
                    total += n;
                    if (total > limit || total > Integer.MAX_VALUE)
                        throw new IOException("Download excedeu o limite permitido");
                    digest.update(buf, 0, n);
                    out.write(buf, 0, n);
                }
                if (expectedLength != null && total != expectedLength)
                    throw new IOException("Tamanho do download inválido");
                if (expectedHash != null && !hex(digest.digest()).equals(expectedHash))
                    throw new IOException("SHA-256 do download não corresponde ao catálogo");
                return out.toByteArray();
            }
        } finally {
            connection.disconnect();
        }
    }

    // Stream large releases to disk; do not hold 80-500 MiB in Java heap.
    static File downloadRelease(Context context, JSONObject release) throws Exception {
        String url = release.getString("url");
        if (!url.startsWith(RELEASE_PREFIX)) throw new IOException("URL Krypt não autorizada");
        long size = release.getLong("size");
        if (size <= 0 || size > ARCHIVE_LIMIT) throw new IOException("Tamanho de pacote inválido");
        String expected = release.getString("sha256");
        if (!hashFormat(expected)) throw new IOException("Hash de pacote inválido");
        File tmp = File.createTempFile("krypt-", ".tar.xz", context.getCacheDir());
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(30000);
        conn.setInstanceFollowRedirects(true);
        try {
            if (conn.getResponseCode() != 200) throw new IOException("HTTP " + conn.getResponseCode());
            if (!"https".equalsIgnoreCase(conn.getURL().getProtocol()))
                throw new IOException("Redirecionamento inseguro");
            MessageDigest sha = MessageDigest.getInstance("SHA-256");
            long count = 0;
            try (InputStream in = conn.getInputStream(); OutputStream out = new FileOutputStream(tmp)) {
                byte[] buf = new byte[65536];
                for (int n; (n = in.read(buf)) != -1;) {
                    if (n == 0) continue;
                    count += n;
                    if (count > size) throw new IOException("Download excedeu tamanho Krypt");
                    sha.update(buf, 0, n);
                    out.write(buf, 0, n);
                }
            }
            if (count != size || !hex(sha.digest()).equals(expected))
                throw new IOException("Falha na verificação SHA-256 do Krypt");
            return tmp;
        } catch (Exception e) {
            tmp.delete();
            throw e;
        } finally {
            conn.disconnect();
        }
    }

    synchronized List<JSONObject> installed() throws Exception {
        JSONArray entries = index().getJSONArray("mods");
        List<JSONObject> out = new ArrayList<>();
        for (int i = 0; i < entries.length(); i++) out.add(entries.getJSONObject(i));
        return out;
    }

    synchronized JSONObject installFile(Uri source) throws Exception {
        if (!root.exists() && !root.mkdirs()) throw new IOException("Não foi possível criar mods");
        File tmp = File.createTempFile("krypt-upload-", ".tar.xz", context.getCacheDir());
        try {
            try (InputStream in = context.getContentResolver().openInputStream(source);
                 FileOutputStream output = new FileOutputStream(tmp)) {
                if (in == null) throw new IOException("Arquivo não disponível");
                copyBounded(in, output, ARCHIVE_LIMIT);
            }
            return installArchive(tmp);
        } finally {
            tmp.delete();
        }
    }

    synchronized JSONObject installArchive(File archive) throws Exception {
        if (!root.exists() && !root.mkdirs()) throw new IOException("Armazenamento indisponível");
        if (!packages.exists() && !packages.mkdirs()) throw new IOException("Pasta de mods indisponível");
        File stage = new File(root, ".stage-" + UUID.randomUUID());
        if (!stage.mkdirs()) throw new IOException("Não foi possível preparar mod");
        try {
            Map<String, File> contents = unpackTarXz(archive, stage);
            boolean current = contents.containsKey("mod.json");
            if (current && contents.containsKey("manifest.json"))
                throw new IOException("Pacote Krypt contém dois manifests");
            File manifest = contents.get(current ? "mod.json" : "manifest.json");
            if (manifest == null || manifest.length() > 8L*1024*1024)
                throw new IOException("Pacote não contém mod.json válido");
            byte[] manifestBytes = readLimited(manifest, 8 * 1024 * 1024);
            JSONObject info = new JSONObject(new String(manifestBytes, StandardCharsets.UTF_8));
            int schema = info.getInt("schema");
            if ((schema != 1 && schema != 2) ||
                !GAME_SHA.equals(info.getJSONObject("game").getString("xbe_sha256")))
                throw new IOException("Mod feito para outra versão de Shaolin");
            String id = info.getString("id"), type = info.getString("type");
            if (!id.matches("[A-Za-z0-9_-]{1,80}")) throw new IOException("ID de mod inválido");
            if (!type.equals("language") && !type.equals("texture") &&
                !type.equals("data") && !type.equals("gameplay") && !type.equals("mixed"))
                throw new IOException("Tipo de mod não suportado");
            String installDir = info.getString("install_dir");
            String requiredDir = (type.equals("language") ? "languages/" : "packages/") + id;
            if (!requiredDir.equals(installDir)) throw new IOException("Diretório Krypt incompatível");
            String version = info.getString("version");
            if (!version.matches("[0-9]+\\.[0-9]+\\.[0-9]+([+.-][A-Za-z0-9.-]+)?"))
                throw new IOException("Versão do mod inválida");
            if (compareVersions(info.getString("recomp"), "0.2.0") > 0)
                throw new IOException("Mod exige Recomp mais novo que 0.2.0");
            JSONArray features = info.optJSONArray("features");
            if (features != null) for (int i = 0; i < features.length(); i++) {
                String feature = features.getString(i);
                if (!feature.matches("files|gamedata|voices|fonts|movies|lua"))
                    throw new IOException("Função Krypt desconhecida: " + feature);
            }
            JSONArray payloads = info.getJSONArray("files"), patches = info.getJSONArray("patches");
            if (payloads.length() + patches.length() > 20000 ||
                payloads.length() + patches.length() == 0)
                throw new IOException("Quantidade inválida de arquivos");
            Set<String> expected = new HashSet<>();
            expected.add(current ? "mod.json" : "manifest.json");
            for (int i=0;i<payloads.length();i++) {
                JSONObject payload = payloads.getJSONObject(i);
                String p=payload.getString("path");
                if (!validPath(p) || !expected.add(p))
                    throw new IOException("Caminho duplicado ou inseguro");
                File file = contents.get(p);
                long size=payload.getLong("size");
                if (file == null || size<0 || size>FILE_LIMIT || file.length()!=size ||
                    !payload.getString("sha256").equals(hashFile(file)))
                    throw new IOException("Integridade Krypt inválida: " + p);
            }
            for (int i=0;i<patches.length();i++) {
                String p=patches.getJSONObject(i).getString("path")+".xdelta";
                if (!validPath(p) || !expected.add(p) || !contents.containsKey(p))
                    throw new IOException("Patch Krypt inválido: " + p);
            }
            JSONArray routines = info.optJSONArray("routines");
            if (routines != null) for (int i=0;i<routines.length();i++) {
                String script = routines.getString(i);
                if (!script.startsWith("scripts/") || !script.endsWith(".lua") ||
                    !expected.contains(script))
                    throw new IOException("Script Lua não declarado pelo mod");
            }
            for (String name : contents.keySet()) if (!expected.contains(name))
                throw new IOException("Arquivo não declarado no pacote: " + name);

            JSONObject registryBefore=index();
            JSONArray old=registryBefore.getJSONArray("mods");
            JSONArray updated=new JSONArray();
            boolean enabled=true;
            for (int i=0;i<old.length();i++) {
                JSONObject row=old.getJSONObject(i);
                if (id.equals(row.getString("id"))) {
                    enabled=row.optBoolean("enabled",true);
                } else updated.put(row);
            }
            JSONObject item=new JSONObject();
            item.put("id",id);item.put("name",info.getString("name"));
            item.put("summary",info.optString("summary",""));
            item.put("type",type);item.put("version",version);
            item.put("language",info.optString("language",""));
            item.put("enabled",enabled);item.put("manifest",info);
            updated.put(item);
            checkCompatibility(updated);
            File destination=new File(packages,id);
            File backup=new File(root,".backup-"+UUID.randomUUID());
            if (destination.exists() && !destination.renameTo(backup))
                throw new IOException("Não foi possível proteger o mod anterior");
            if (!stage.renameTo(destination)) {
                if (backup.exists()) backup.renameTo(destination);
                throw new IOException("Não foi possível instalar o novo pacote");
            }
            try {
                JSONObject state=new JSONObject();
                state.put("mods",updated);
                saveIndex(state);
                deleteRecursively(backup);
                return item;
            } catch (Exception e) {
                deleteRecursively(destination);
                if (backup.exists()) backup.renameTo(destination);
                throw e;
            }
        } finally {
            deleteRecursively(stage);
        }
    }

    synchronized void enable(String id,boolean enabled) throws Exception {
        JSONObject state=index();
        JSONArray mods=state.getJSONArray("mods");
        boolean found=false;
        for(int i=0;i<mods.length();i++){
            JSONObject mod=mods.getJSONObject(i);
            if(id.equals(mod.getString("id"))) {mod.put("enabled",enabled);found=true;}
        }
        if(!found)throw new IOException("Mod não encontrado");
        checkCompatibility(mods);
        saveIndex(state);
    }

    synchronized void remove(String id) throws Exception {
        JSONObject state=index();JSONArray mods=state.getJSONArray("mods");
        JSONArray updated=new JSONArray();
        boolean found=false;
        for(int i=0;i<mods.length();i++) {
            JSONObject m=mods.getJSONObject(i);
            if(id.equals(m.getString("id"))) found=true; else updated.put(m);
        }
        if(!found) throw new IOException("Mod não encontrado");
        checkCompatibility(updated);
        File destination=new File(packages,id);
        File backup=new File(root,".remove-"+UUID.randomUUID());
        if(destination.exists() && !destination.renameTo(backup)) throw new IOException("Falha ao preparar exclusão");
        try {
            state.put("mods",updated);saveIndex(state);deleteRecursively(backup);
        } catch(Exception e) {
            if(backup.exists())backup.renameTo(destination);
            throw e;
        }
    }

    private JSONObject index() throws Exception {
        if(!registry.exists()){JSONObject o=new JSONObject();o.put("mods",new JSONArray());return o;}
        return new JSONObject(new String(readLimited(registry,8*1024*1024),StandardCharsets.UTF_8));
    }

    private void saveIndex(JSONObject state) throws IOException {
        if(!root.exists() && !root.mkdirs())throw new IOException("Mods storage unavailable");
        File tmp=File.createTempFile("index-",".tmp",root);
        try(FileOutputStream output=new FileOutputStream(tmp)){
            output.write(state.toString(2).getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
        if(!tmp.renameTo(registry)){ // some filesystems require deleting old destination first
            File backup=new File(root,"index.previous");
            if(backup.exists())backup.delete();
            if(registry.exists()&&!registry.renameTo(backup))throw new IOException("Registry is locked");
            if(!tmp.renameTo(registry)) {
                if(backup.exists())backup.renameTo(registry);
                throw new IOException("Cannot save mod state");
            }
            backup.delete();
        }
    }

    private static void checkCompatibility(JSONArray rows) throws Exception {
        Map<String,JSONObject> map=new HashMap<>();
        for(int i=0;i<rows.length();i++){
            JSONObject m=rows.getJSONObject(i);
            if(m.optBoolean("enabled",false))map.put(m.getString("id"),m);
        }
        Set<String> claims=new HashSet<>();
        Set<String> languages=new HashSet<>();
        for(JSONObject m:map.values()) {
            JSONObject info=m.getJSONObject("manifest");
            JSONArray deps=info.optJSONArray("dependencies");
            if(deps!=null)for(int i=0;i<deps.length();i++){
                JSONObject d=deps.getJSONObject(i); JSONObject needed=map.get(d.getString("id"));
                if(needed==null||compareVersions(needed.getString("version"),d.getString("version"))<0)
                    throw new IOException(m.getString("name")+" depende do mod "+d.getString("id")+" habilitado");
            }
            JSONArray conflicts=info.optJSONArray("conflicts");
            if(conflicts!=null)for(int i=0;i<conflicts.length();i++)
                if(map.containsKey(conflicts.getString(i)))
                    throw new IOException("Conflito declarado entre mods: "+m.getString("id"));
            if("language".equals(m.getString("type"))) {
                String code=m.optString("language").toLowerCase(Locale.ROOT);
                if(!languages.add(code))throw new IOException("Dois mods oferecem o mesmo idioma");
                continue;
            }
            JSONArray payloads=info.getJSONArray("files");
            for(int i=0;i<payloads.length();i++){
                String p=payloads.getJSONObject(i).getString("path").toLowerCase(Locale.ROOT);
                if(!claims.add(p))throw new IOException("Dois mods substituem o mesmo recurso: "+p);
            }
        }
    }

    static int compareVersions(String a,String b){
        String[] aa=a.split("[+\\-]",2)[0].split("\\.");
        String[] bb=b.split("[+\\-]",2)[0].split("\\.");
        if(aa.length!=3||bb.length!=3)throw new IllegalArgumentException("Versão inválida");
        for(int i=0;i<3;i++){int x=Integer.parseInt(aa[i]);int y=Integer.parseInt(bb[i]);if(x!=y)return Integer.compare(x,y);}
        return 0;
    }

    private static Map<String,File> unpackTarXz(File archive,File destination) throws Exception {
        Map<String,File> contents=new HashMap<>();
        Set<String> names=new HashSet<>();
        long total=0;
        try(InputStream in=new XZInputStream(new FileInputStream(archive))) {
            byte[] header=new byte[512];
            boolean ended=false;
            for(int count=0;count<20000;count++){
                readFully(in,header,0,512);
                boolean zero=true;for(byte b:header)if(b!=0){zero=false;break;}
                if(zero){
                    readFully(in,header,0,512);
                    for(byte b:header)if(b!=0)throw new IOException("Fim TAR inválido");
                    ended=true;break;
                }
                long checksum=octal(header,148,8),sum=0;
                for(int i=0;i<512;i++)sum+= i>=148&&i<156?32:(header[i]&255);
                if(sum!=checksum)throw new IOException("Checksum TAR inválido");
                String typeTag=new String(header,257,5,StandardCharsets.US_ASCII);
                if(!typeTag.equals("ustar"))throw new IOException("O pacote requer TAR USTAR");
                String name=tarField(header,0,100);
                String prefix=tarField(header,345,155);
                if(!prefix.isEmpty())name=prefix+"/"+name;
                byte type=header[156];
                boolean folder=type=='5';
                if(folder&&name.endsWith("/"))name=name.substring(0,name.length()-1);
                if(!validPath(name) || (type!=0 && type!='0' && !folder))
                    throw new IOException("Caminho ou tipo TAR perigoso: "+name);
                if(!names.add(name.toLowerCase(Locale.ROOT)))throw new IOException("Nome TAR duplicado");
                long size=octal(header,124,12);
                if(size<0 || size>FILE_LIMIT || (folder && size!=0))throw new IOException("Tamanho TAR inválido");
                total+=size;if(total>TOTAL_LIMIT)throw new IOException("Mod descompactado excede 1 GiB");
                File file=new File(destination,name);
                if(!file.getCanonicalPath().startsWith(destination.getCanonicalPath()+File.separator))
                    throw new IOException("Caminho sai da pasta segura");
                if(folder){if(!file.mkdirs()&&!file.isDirectory())throw new IOException("Não foi possível criar pasta");continue;}
                File parent=file.getParentFile();
                if(!parent.isDirectory()&&!parent.mkdirs())throw new IOException("Falha ao criar diretório");
                if(file.exists())throw new IOException("Arquivo duplicado");
                try(OutputStream out=new FileOutputStream(file)){
                    long remain=size;byte[] buf=new byte[65536];
                    while(remain>0){
                        int n=(int)Math.min(buf.length,remain);
                        readFully(in,buf,0,n);
                        out.write(buf,0,n);remain-=n;
                    }
                }
                long pad=(512-(size%512))%512;
                if(pad>0)readFully(in,new byte[(int)pad],0,(int)pad);
                contents.put(name,file);
            }
            if(!ended)throw new IOException("TAR excede limite de entradas");
        }
        return contents;
    }
    private static String tarField(byte[] b,int at,int len){
        int n=0;while(n<len && b[at+n]!=0)n++;
        return new String(b,at,n,StandardCharsets.UTF_8);
    }
    private static long octal(byte[] b,int at,int len)throws IOException{
        String s=tarField(b,at,len).trim();if(s.isEmpty())return 0;
        if(!s.matches("[0-7]+"))throw new IOException("Número TAR inválido");
        return Long.parseLong(s,8);
    }
    private static boolean validPath(String p){
        if(p==null||p.isEmpty()||p.length()>512||p.startsWith("/")||p.contains("\\")||
           p.contains(":")||p.indexOf(0)>=0)return false;
        for(String segment:p.split("/",-1))if(segment.isEmpty()||segment.equals(".")||segment.equals(".."))return false;
        return true;
    }
    private static void copyBounded(InputStream in,OutputStream out,long max)throws IOException{
        byte[] buf=new byte[65536];long n=0;
        for(int count;(count=in.read(buf))!=-1;){n+=count;if(n>max)throw new IOException("Arquivo Krypt muito grande");out.write(buf,0,count);}
    }
    private static void readFully(InputStream in,byte[] data,int start,int len)throws IOException{
        while(len>0){int n=in.read(data,start,len);if(n<1)throw new IOException("Pacote Krypt truncado");len-=n;start+=n;}
    }
    private static byte[] readLimited(File f,int limit)throws IOException{
        if(f.length()>limit)throw new IOException("Arquivo excede limite");
        try(FileInputStream in=new FileInputStream(f);ByteArrayOutputStream out=new ByteArrayOutputStream()) {
            copyBounded(in,out,limit);return out.toByteArray();
        }
    }
    private static String hashFile(File f)throws Exception{
        MessageDigest sha=MessageDigest.getInstance("SHA-256");
        try(FileInputStream in=new FileInputStream(f)){
            byte[] buf=new byte[65536];for(int n;(n=in.read(buf))!=-1;)sha.update(buf,0,n);
        }
        return hex(sha.digest());
    }
    private static boolean hashFormat(String s){return s!=null&&s.matches("[0-9a-f]{64}");}
    private static String hex(byte[] data){
        char[] hex="0123456789abcdef".toCharArray();char[] out=new char[data.length*2];
        for(int i=0;i<data.length;i++){out[i*2]=hex[(data[i]&255)>>>4];out[i*2+1]=hex[data[i]&15];}
        return new String(out);
    }
    private static void deleteRecursively(File f){
        if(f==null||!f.exists())return;
        File[] children=f.listFiles();if(children!=null)for(File x:children)deleteRecursively(x);
        f.delete();
    }
}
