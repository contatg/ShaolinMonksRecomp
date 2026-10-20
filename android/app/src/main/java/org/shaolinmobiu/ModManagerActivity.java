package org.shaolinmobiu;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Native Android Krypt management UI.
 * Packages are installed into private verified staging storage; options are
 * persisted. The original Xbox runtime has not been wired to consume them.
 */
public final class ModManagerActivity extends Activity {
    private static final int PICK_MOD = 1842;
    private static final int BG=Color.rgb(12,11,17), PANEL=Color.rgb(25,22,31);
    private static final int RED=Color.rgb(220,57,64), GOLD=Color.rgb(245,179,91);
    private static final int WHITE=Color.rgb(248,243,235), MUTED=Color.rgb(174,169,181);
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private ModStore store;
    private LinearLayout content;
    private TextView progress;
    private JSONObject catalog;
    private boolean busy=false;

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        store=new ModStore(this);
        ScrollView scroll=new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(BG);
        content=new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(20),dp(22),dp(20),dp(30));
        scroll.addView(content);
        setContentView(scroll);
        buildHeader();
        refreshInstalled();
    }

    private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
    private GradientDrawable panel(int color,int stroke){
        GradientDrawable d=new GradientDrawable();
        d.setColor(color);d.setCornerRadius(dp(17));d.setStroke(dp(1),stroke);return d;
    }
    private TextView text(String value,int size,int color,boolean bold){
        TextView t=new TextView(this);
        t.setText(value);t.setTextSize(size);t.setTextColor(color);
        t.setIncludeFontPadding(false);
        if(bold)t.setTypeface(Typeface.create("sans-serif",Typeface.BOLD));
        return t;
    }
    private LinearLayout column(){
        LinearLayout l=new LinearLayout(this);l.setOrientation(LinearLayout.VERTICAL);return l;
    }
    private LinearLayout.LayoutParams params(int top,int bottom){
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);
        p.setMargins(0,dp(top),0,dp(bottom));return p;
    }
    private Button button(String label,boolean red,Runnable click) {
        Button b=new Button(this);b.setAllCaps(false);b.setText(label);b.setTextSize(14);
        b.setTextColor(WHITE);b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setMinHeight(dp(49));
        b.setBackground(panel(red?Color.rgb(130,31,46):Color.rgb(39,33,43),
            red?RED:Color.rgb(62,53,64)));
        b.setOnClickListener(v->{if(!busy)click.run();});
        return b;
    }
    private void buildHeader(){
        TextView title=text("KRYPT  /  MODS",28,WHITE,true);
        content.addView(title);
        content.addView(text("Pacotes de Mortal Kombat: Shaolin Monks",13,GOLD,true),params(7,19));

        LinearLayout warning=column();
        warning.setPadding(dp(16),dp(16),dp(16),dp(16));
        warning.setBackground(panel(Color.rgb(55,36,37),Color.rgb(123,69,59)));
        warning.addView(text("INSTALADOR KRYPT — PRÉVIA",12,GOLD,true));
        TextView body=text("Os pacotes .tar.xz são extraídos e verificados com SHA-256. " +
            "Você pode instalar, atualizar e organizar os mods. " +
            "O jogo Android ainda NÃO usa esses arquivos: aplicar mods e scripts Lua " +
            "depende do motor Xbox, que está sendo portado.",13,WHITE,false);
        body.setLineSpacing(dp(4),1f);
        warning.addView(body,params(9,0));
        content.addView(warning);

        content.addView(button("Importar mod Krypt (.tar.xz)",true,this::pickMod),params(18,0));
        content.addView(button("Buscar catálogo e atualizações",false,this::refreshCatalog),params(9,0));
        progress=text("Pacotes preparados são guardados somente neste celular.",12,MUTED,false);
        progress.setGravity(Gravity.CENTER);
        content.addView(progress,params(15,20));
    }
    private void status(String value){progress.setText(value);}
    private void section(String heading){
        TextView title=text(heading,13,GOLD,true);
        title.setLetterSpacing(0.12f);
        content.addView(title,params(14,12));
    }
    private void clearRows(){
        for(int i=content.getChildCount()-1;i>=5;i--)content.removeViewAt(i);
    }
    private void refreshInstalled(){
        run("Lendo pacotes instalados...",()->{
            List<JSONObject> installed=store.installed();
            runOnUiThread(()->render(installed));
        });
    }
    private void render(List<JSONObject> installed){
        // Keep title, subtitle, warning, two buttons and status.
        while(content.getChildCount()>6)content.removeViewAt(content.getChildCount()-1);
        section("PACOTES NO APARELHO  ("+installed.size()+")");
        if(installed.isEmpty())
            content.addView(text("Nenhum mod Krypt instalado.",14,MUTED,false),params(0,9));
        for(JSONObject item:installed){
            String id=item.optString("id"),name=item.optString("name"),
                   version=item.optString("version"),type=item.optString("type");
            LinearLayout box=column();box.setPadding(dp(15),dp(15),dp(15),dp(15));
            box.setBackground(panel(PANEL,Color.rgb(59,48,60)));
            box.addView(text(name,16,WHITE,true));
            box.addView(text(type+" • v"+version+" • "+id,12,GOLD,false),params(7,0));
            String summary=item.optString("summary");
            if(!summary.isEmpty())box.addView(text(summary,12,MUTED,false),params(9,0));
            Switch toggle=new Switch(this);
            toggle.setText("Habilitar ao portar motor Xbox");
            toggle.setTextColor(WHITE);
            toggle.setTextSize(12);
            toggle.setChecked(item.optBoolean("enabled",false));
            toggle.setOnCheckedChangeListener((b,checked)->{
                if(busy){b.setChecked(!checked);return;}
                run(checked?"Ativando preferência...":"Desativando preferência...",()->{
                    store.enable(id,checked);
                    List<JSONObject> current=store.installed();
                    runOnUiThread(()->render(current));
                });
            });
            box.addView(toggle,params(11,0));
            box.addView(button("Remover pacote",false,()->
                new AlertDialog.Builder(this).setTitle("Remover "+name+"?")
                    .setMessage("O pacote será apagado do armazenamento privado do aplicativo.")
                    .setNegativeButton("Cancelar",null)
                    .setPositiveButton("Remover",(d,w)->run("Removendo "+name,()->{
                        store.remove(id);
                        List<JSONObject> current=store.installed();
                        runOnUiThread(()->render(current));
                    })).show()
            ),params(9,0));
            content.addView(box,params(0,12));
        }
        if(catalog!=null){
            section("CATÁLOGO KRYPT");
            JSONArray mods=catalog.optJSONArray("mods");
            if(mods!=null){
                for(int i=0;i<mods.length();i++){
                    JSONObject mod=mods.optJSONObject(i);if(mod==null)continue;
                    JSONArray versions=mod.optJSONArray("versions");
                    JSONObject compatible=null;
                    if(versions!=null)for(int j=0;j<versions.length();j++){
                        JSONObject v=versions.optJSONObject(j);
                        if(v==null)continue;
                        try{
                            if(ModStore.compareVersions(v.getString("recomp"),"0.2.0")<=0 &&
                                (compatible==null ||
                                ModStore.compareVersions(v.getString("version"),compatible.getString("version"))>0))
                                compatible=v;
                        }catch(Exception ignored){}
                    }
                    if(compatible==null)continue;
                    String id=mod.optString("id"),name=mod.optString("name",id);
                    boolean installedLatest=false;
                    for(JSONObject item:installed)if(id.equals(item.optString("id"))){
                        try{installedLatest=ModStore.compareVersions(
                             item.getString("version"),compatible.getString("version"))>=0;}
                        catch(Exception ignored){}
                    }
                    LinearLayout box=column();
                    box.setPadding(dp(15),dp(15),dp(15),dp(15));
                    box.setBackground(panel(PANEL,Color.rgb(60,46,58)));
                    box.addView(text(name,16,WHITE,true));
                    box.addView(text(mod.optString("summary"),12,MUTED,false),params(7,0));
                    final JSONObject selected=compatible;
                    if(installedLatest){
                        box.addView(text("✓  Versão mais recente preparada",12,GOLD,true),params(9,0));
                    }else{
                        String version=compatible.optString("version","?");
                        long mb=compatible.optLong("size")/(1024*1024);
                        box.addView(button("Baixar v"+version+"  •  "+mb+" MB",false,
                            ()->new AlertDialog.Builder(this)
                                .setTitle("Instalar "+name+"?")
                                .setMessage("O arquivo será baixado do Krypt oficial, verificado por SHA-256 e " +
                                    "guardado no aplicativo. Ainda não será aplicado ao jogo Android.")
                                .setNegativeButton("Cancelar",null)
                                .setPositiveButton("Baixar",(d,w)->download(id,selected))
                                .show()),params(12,0));
                    }
                    content.addView(box,params(0,12));
                }
            }
        }
        content.addView(text("Origem: OAleeX/ShaolinMonksRecompKrypt • nenhum XBE é enviado.",11,MUTED,false),params(20,0));
    }
    private void pickMod(){
        Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.setType("*/*");intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivityForResult(intent,PICK_MOD);
    }
    @Override protected void onActivityResult(int req,int result,Intent data){
        super.onActivityResult(req,result,data);
        if(req!=PICK_MOD||result!=RESULT_OK||data==null||data.getData()==null)return;
        String name="";Uri uri=data.getData();
        try(Cursor cursor=getContentResolver().query(uri,
            new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){
            if(cursor!=null&&cursor.moveToFirst())name=cursor.getString(0);
        }catch(Exception ignored){}
        if(!name.toLowerCase(Locale.ROOT).endsWith(".tar.xz")){
            Toast.makeText(this,"Escolha pacote Krypt .tar.xz",Toast.LENGTH_LONG).show();return;
        }
        run("Verificando e extraindo "+name+"...",()->{
            JSONObject item=store.installFile(uri);
            List<JSONObject> current=store.installed();
            runOnUiThread(()->{status("Krypt "+item.optString("name")+" preparado com segurança");render(current);});
        });
    }
    private void refreshCatalog(){
        run("Consultando catálogo Krypt oficial...",()->{
            JSONObject next=ModStore.downloadCatalog();
            List<JSONObject> installed=store.installed();
            runOnUiThread(()->{catalog=next;status("Catálogo atualizado");render(installed);});
        });
    }
    private void download(String id,JSONObject release){
        run("Baixando e verificando "+id+"...",()->{
            File archive=ModStore.downloadRelease(this,release);
            try{
                JSONObject prepared=store.installArchive(archive);
                if(!id.equals(prepared.optString("id"))||
                    !release.getString("version").equals(prepared.optString("version")))
                    throw new IllegalStateException("Mod baixado não corresponde ao catálogo");
            }finally{archive.delete();}
            List<JSONObject> installed=store.installed();
            runOnUiThread(()->{status("Pacote Krypt instalado, aguardando motor do jogo");render(installed);});
        });
    }
    private interface Task{void execute()throws Exception;}
    private void run(String label,Task task){
        if(busy)return;busy=true;status(label);
        worker.execute(()->{
            try{
                task.execute();
            }catch(Exception e){
                runOnUiThread(()->{
                    status("Erro: "+e.getMessage());
                    new AlertDialog.Builder(this).setTitle("Krypt")
                        .setMessage(e.getMessage()).setPositiveButton("OK",null).show();
                });
            }finally{runOnUiThread(()->busy=false);}
        });
    }
    @Override protected void onDestroy(){
        worker.shutdown();super.onDestroy();
    }
}
