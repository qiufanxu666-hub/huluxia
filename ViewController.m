#import "ViewController.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../Core/HXScriptStore.h"

static NSString * const HXTargetsKey = @"HXAllowedBundleIDs";

@interface ViewController () <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate>
@property(nonatomic,strong) WKWebView *webView;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIView *toastView;
@property(nonatomic,strong) NSMutableArray<NSString *> *targets;
@property(nonatomic,copy) NSString *pendingImportRequestID;
@property(nonatomic,copy) NSString *pendingExportRequestID;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"葫芦侠";
    self.targets = [[[NSUserDefaults standardUserDefaults] arrayForKey:HXTargetsKey] mutableCopy] ?: [NSMutableArray array];
    [self buildInterface];
    [self loadLegacyPage];
}

- (void)buildInterface {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    WKUserContentController *content = [WKUserContentController new];
    [content addScriptMessageHandler:self name:@"hx"];
    NSString *bridge = @"(function(){if(window.huluxiaNative)return;let seq=0;const pending={};window.addEventListener('huluxia-native-result',function(e){const d=e.detail||{};const p=pending[d.requestId];if(!p)return;delete pending[d.requestId];d.error?p.reject(new Error(d.error)):p.resolve(d.value);});function call(action,extra){return new Promise((resolve,reject)=>{const requestId='hx-'+(++seq);pending[requestId]={resolve,reject};try{window.webkit.messageHandlers.hx.postMessage(Object.assign({action:action,requestId:requestId},extra||{}));}catch(e){delete pending[requestId];reject(e);}});}window.huluxiaNative={version:'0.5.0',toast:(message)=>call('toast',{message:String(message)}),alert:(message,title)=>call('alert',{message:String(message),title:title?String(title):'提示'}),copyText:(text)=>call('copyText',{text:String(text)}),log:(message)=>call('log',{message:String(message)}),getInfo:()=>call('getInfo'),pickTextFile:()=>call('pickTextFile'),shareTextFile:(filename,text)=>call('shareTextFile',{filename:String(filename||'script.lua'),text:String(text??'')})};})();";
    WKUserScript *userScript = [[WKUserScript alloc] initWithSource:bridge injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [content addUserScript:userScript];
    NSString *luaFileAdapter = @"(function(){if(!window.huluxiaNative)return;window.triggerImportLua=function(){window.huluxiaNative.pickTextFile().then(function(file){if(!file||typeof file.text!=='string')return;var name=String(file.name||'script.lua');if(!/\\.(lua|txt)$/i.test(name)){window.huluxiaNative.toast('请选择 .lua 或 .txt 文件');return;}if(file.text.length>4*1024*1024){window.huluxiaNative.toast('文件超过 4 MB，无法导入');return;}var editor=document.getElementById('luaEditor');if(editor)editor.value=file.text;var nameInput=document.getElementById('luaScriptName');if(nameInput)nameInput.value=name.replace(/\\.(lua|txt)$/i,'');if(typeof window.luaOutReset==='function')window.luaOutReset();if(typeof window.luaOutLine==='function'){window.luaOutLine('已从 iOS 文件选择器导入: '+name,'#79c0ff');window.luaOutLine('行数: '+file.text.split('\\n').length,'var(--c-text-dim)');}if(typeof window.setTab==='function')window.setTab(3);window.huluxiaNative.toast('已导入: '+name);}).catch(function(e){if(e&&e.message!=='用户取消了文件选择')window.huluxiaNative.alert(e.message,'导入失败');});};window.exportLuaFile=function(){var editor=document.getElementById('luaEditor');var code=editor?editor.value:'';if(!code.trim()){window.huluxiaNative.toast('编辑器为空，无内容可导出');return;}var nameInput=document.getElementById('luaScriptName');var name=nameInput&&nameInput.value.trim()?nameInput.value.trim():'hulu_script_'+Date.now();name=name.replace(/[<>:\"\\/\\\\|?*]/g,'_');if(!/\\.lua$/i.test(name))name+='.lua';if(code.indexOf('-- [葫芦侠脚本]')<0)code='-- [葫芦侠脚本] '+name+'\\n-- 导出时间: '+new Date().toLocaleString('zh-CN')+'\\n\\n'+code;window.huluxiaNative.shareTextFile(name,code).then(function(ok){if(ok){window.huluxiaNative.toast('已打开系统分享/存储面板');if(typeof window.log==='function')window.log('Lua 文件已交给 iOS 分享面板','t');}}).catch(function(e){window.huluxiaNative.alert(e.message,'导出失败');});};})();";
    WKUserScript *luaAdapterScript = [[WKUserScript alloc] initWithSource:luaFileAdapter injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [content addUserScript:luaAdapterScript];
    configuration.userContentController = content;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.webView];

    UIView *toolbar = [UIView new];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:toolbar];
    UIButton *reload = [self toolbarButton:@"重新加载" action:@selector(reloadPage)];
    UIButton *targets = [self toolbarButton:@"授权目标" action:@selector(showTargets)];
    UIButton *library = [self toolbarButton:@"Lua 脚本库" action:@selector(showNativeScriptLibrary)];
    UIButton *about = [self toolbarButton:@"桥接说明" action:@selector(showBridgeInfo)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[reload, targets, library, about]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;
    [toolbar addSubview:buttons];
    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"本地 HTML 容器 · 原生桥接已启用";
    [toolbar addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:toolbar.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:68],
        [buttons.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-12],
        [buttons.topAnchor constraintEqualToAnchor:toolbar.topAnchor constant:5],
        [buttons.heightAnchor constraintEqualToConstant:34],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:toolbar.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:3]
    ]];
}

- (UIButton *)toolbarButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    button.layer.cornerRadius = 8;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)loadLegacyPage {
    NSURL *htmlURL = [[NSBundle mainBundle] URLForResource:@"legacy-huluxia" withExtension:@"html"];
    if (!htmlURL) {
        self.statusLabel.text = @"未找到 Resources/legacy-huluxia.html";
        [self showNativeError:@"HTML 资源没有打入 App。请检查 Makefile 中的 HuluXia_RESOURCE_FILES。"];
        return;
    }
    [self.webView loadFileURL:htmlURL allowingReadAccessToURL:htmlURL.URLByDeletingLastPathComponent];
}

- (void)reloadPage { [self loadLegacyPage]; }

#pragma mark - Native bridge

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"hx"] || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    NSString *action = [body[@"action"] isKindOfClass:NSString.class] ? body[@"action"] : @"";
    NSString *requestID = [body[@"requestId"] isKindOfClass:NSString.class] ? body[@"requestId"] : @"";
    NSString *value = [body[@"message"] isKindOfClass:NSString.class] ? body[@"message"] : @"";

    if ([action isEqualToString:@"toast"]) {
        [self showToast:value];
        [self reply:requestID value:@YES error:nil];
    } else if ([action isEqualToString:@"alert"]) {
        NSString *title = [body[@"title"] isKindOfClass:NSString.class] ? body[@"title"] : @"提示";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:value preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self reply:requestID value:@YES error:nil]; }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if ([action isEqualToString:@"copyText"]) {
        NSString *text = [body[@"text"] isKindOfClass:NSString.class] ? body[@"text"] : @"";
        UIPasteboard.generalPasteboard.string = text;
        [self showToast:@"已复制到剪贴板"];
        [self reply:requestID value:@YES error:nil];
    } else if ([action isEqualToString:@"log"]) {
        NSLog(@"[HuluXia Web] %@", value);
        [self reply:requestID value:@YES error:nil];
    } else if ([action isEqualToString:@"getInfo"]) {
        NSDictionary *info = @{@"appVersion": @"0.5.0", @"platform": @"iOS", @"bridge": @"huluxiaNative", @"fileImportExport": @YES, @"memoryModificationAvailable": @NO, @"targets": self.targets ?: @[]};
        [self reply:requestID value:info error:nil];
    } else if ([action isEqualToString:@"pickTextFile"]) {
        if (self.pendingImportRequestID.length || self.pendingExportRequestID.length) {
            [self reply:requestID value:nil error:@"已有文件操作正在进行"];
        } else {
            self.pendingImportRequestID = requestID;
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTType.plainText, UTType.data] asCopy:YES];
            picker.delegate = self;
            picker.allowsMultipleSelection = NO;
            [self presentViewController:picker animated:YES completion:nil];
        }
    } else if ([action isEqualToString:@"shareTextFile"]) {
        if (self.pendingImportRequestID.length || self.pendingExportRequestID.length) {
            [self reply:requestID value:nil error:@"已有文件操作正在进行"];
        } else {
            NSString *filename = [body[@"filename"] isKindOfClass:NSString.class] ? body[@"filename"] : @"script.lua";
            NSString *fileText = [body[@"text"] isKindOfClass:NSString.class] ? body[@"text"] : @"";
            if (filename.length == 0 || [filename containsString:@"/"] || [filename containsString:@"\\"]) filename = @"script.lua";
            if (![filename.pathExtension.lowercaseString isEqualToString:@"lua"] && ![filename.pathExtension.lowercaseString isEqualToString:@"txt"]) filename = [filename stringByAppendingPathExtension:@"lua"];
            NSURL *folder = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
            NSURL *fileURL = [folder URLByAppendingPathComponent:filename];
            NSError *writeError = nil;
            BOOL wrote = [fileText writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
            if (!wrote) {
                [self reply:requestID value:nil error:writeError.localizedDescription ?: @"无法写入临时文件"];
            } else {
                self.pendingExportRequestID = requestID;
                UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
                activity.completionWithItemsHandler = ^(__unused UIActivityType type, BOOL completed, __unused NSArray *items, NSError *error) {
                    NSString *pending = self.pendingExportRequestID;
                    self.pendingExportRequestID = nil;
                    if (error) [self reply:pending value:nil error:error.localizedDescription];
                    else [self reply:pending value:@(completed) error:nil];
                    [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                };
                if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                    activity.popoverPresentationController.sourceView = self.view;
                    activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
                }
                [self presentViewController:activity animated:YES completion:nil];
            }
        }
    } else {
        [self reply:requestID value:nil error:@"不支持的原生桥接操作"];
    }
}

- (void)reply:(NSString *)requestID value:(id)value error:(NSString *)error {
    if (requestID.length == 0) return;
    NSMutableDictionary *payload = [@{@"requestId": requestID} mutableCopy];
    if (value) payload[@"value"] = value;
    if (error) payload[@"error"] = error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    NSString *script = [NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('huluxia-native-result',{detail:%@}));", json];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.webView evaluateJavaScript:script completionHandler:nil]; });
}

- (void)showToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.toastView removeFromSuperview];
        UILabel *label = [UILabel new];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = message.length ? message : @"完成";
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 2;
        label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.9];
        label.layer.cornerRadius = 10;
        label.layer.masksToBounds = YES;
        label.layoutMargins = UIEdgeInsetsMake(9, 15, 9, 15);
        UIView *wrap = [UIView new]; wrap.translatesAutoresizingMaskIntoConstraints = NO;
        [wrap addSubview:label]; [self.view addSubview:wrap];
        [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:12],[label.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-12],[label.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:7],[label.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-7],[wrap.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[wrap.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-78],[wrap.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-36]]];
        self.toastView = wrap;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [wrap removeFromSuperview]; if (self.toastView == wrap) self.toastView = nil; });
    });
}

#pragma mark - Native document picker

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.pendingImportRequestID.length) [self reply:self.pendingImportRequestID value:nil error:@"用户取消了文件选择"];
    self.pendingImportRequestID = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *requestID = self.pendingImportRequestID;
    self.pendingImportRequestID = nil;
    NSURL *url = urls.firstObject;
    if (!url) { [self reply:requestID value:nil error:@"没有选择文件"]; return; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:&readError];
    unsigned long long size = [attributes fileSize];
    if (readError || size > 4 * 1024 * 1024) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        [self reply:requestID value:nil error:readError.localizedDescription ?: @"文件过大（限制 4 MB）"];
        return;
    }
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&readError];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!text) [self reply:requestID value:nil error:readError.localizedDescription ?: @"文件不是有效的 UTF-8 文本"];
    else [self reply:requestID value:@{@"name": url.lastPathComponent ?: @"script.lua", @"text": text} error:nil];
}

#pragma mark - Target configuration

- (void)showTargets {
    NSString *current = self.targets.count ? [self.targets componentsJoinedByString:@"\n"] : @"尚未添加目标";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"授权测试目标" message:[NSString stringWithFormat:@"当前列表：\n%@\n\n这里只保存构建配置，不会动态注入进程。", current] preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Bundle ID，例如 com.example.app"; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *bundle = [sheet.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (bundle.length && [bundle containsString:@"."] && ![bundle containsString:@" "] && ![weakSelf.targets containsObject:bundle]) [weakSelf.targets addObject:bundle];
        [[NSUserDefaults standardUserDefaults] setObject:weakSelf.targets forKey:HXTargetsKey];
        [weakSelf showTargets];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制构建变量" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *joined = [weakSelf.targets componentsJoinedByString:@","];
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"TARGET_BUNDLES=\"%@\"", joined ?: @""];
        [weakSelf showToast:@"构建变量已复制"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清空列表" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { [weakSelf.targets removeAllObjects]; [[NSUserDefaults standardUserDefaults] setObject:weakSelf.targets forKey:HXTargetsKey]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) { sheet.popoverPresentationController.sourceView = self.view; sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds)-100, 1, 1); }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Native Lua script library
- (void)showNativeScriptLibrary {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"原生 Lua 脚本库" message:@"脚本保存在本 App 的 Documents/LuaScripts 目录；加载只填入编辑器，不会自动执行。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"保存当前编辑器内容" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf saveCurrentEditorToNativeLibrary];}]];
    NSError *err=nil; NSArray *items=[[HXScriptStore sharedStore] allScripts:&err]; if(err)[self showNativeError:err.localizedDescription];
    NSUInteger count=MIN(items.count,12);
    for(NSUInteger i=0;i<count;i++){NSString *name=items[i][@"name"]?:@"未命名"; [sheet addAction:[UIAlertAction actionWithTitle:[@"加载：" stringByAppendingString:name] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf loadNativeScriptNamed:name];}]];}
    if(items.count==0)[sheet addAction:[UIAlertAction actionWithTitle:@"脚本库为空" style:UIAlertActionStyleDefault handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    if(UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad){sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMaxY(self.view.bounds)-100,1,1);}
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)saveCurrentEditorToNativeLibrary {
    NSString *js=@"(function(){var e=document.getElementById('luaEditor'),n=document.getElementById('luaScriptName');return {name:n&&n.value?n.value:'script',code:e?e.value:''};})()";
    [self.webView evaluateJavaScript:js completionHandler:^(id result,NSError *error){
        if(error||![result isKindOfClass:NSDictionary.class]){[self showNativeError:error.localizedDescription?:@"无法读取 Lua 编辑器内容"];return;}
        NSString *name=[result[@"name"] isKindOfClass:NSString.class]?result[@"name"]:@"script"; NSString *code=[result[@"code"] isKindOfClass:NSString.class]?result[@"code"]:@"";
        if(!code.length){[self showToast:@"编辑器为空，未保存"];return;} NSError *saveError=nil;
        if([[HXScriptStore sharedStore] saveScriptNamed:name code:code error:&saveError])[self showToast:[NSString stringWithFormat:@"已保存：%@",name]]; else [self showNativeError:saveError.localizedDescription?:@"保存失败"];
    }];
}
- (void)loadNativeScriptNamed:(NSString *)name {
    NSError *err=nil; NSString *code=[[HXScriptStore sharedStore] loadScriptNamed:name error:&err]; if(!code){[self showNativeError:err.localizedDescription?:@"脚本读取失败"];return;}
    NSDictionary *payload=@{@"name":name?:@"script",@"code":code}; NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingFragmentsAllowed error:nil]; NSString *json=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:@"{}";
    NSString *js=[NSString stringWithFormat:@"(function(d){var e=document.getElementById('luaEditor'),n=document.getElementById('luaScriptName');if(e)e.value=d.code;if(n)n.value=d.name;if(typeof window.luaOutReset==='function')window.luaOutReset();if(typeof window.luaOutLine==='function')window.luaOutLine('已从原生脚本库加载：'+d.name,'#79c0ff');if(typeof window.setTab==='function')window.setTab(3);})(%@);",json];
    [self.webView evaluateJavaScript:js completionHandler:^(id result,NSError *error){if(error)[self showNativeError:error.localizedDescription];else [self showToast:[NSString stringWithFormat:@"已加载：%@",name]];}];
}

- (void)showBridgeInfo {
    NSString *message = @"已提供：网页调用原生提示、弹窗、剪贴板、日志和基础信息。\n\n未提供：h5gg 内存读写、任意进程注入、冻结和游戏变速。原 HTML 中依赖 h5gg 的功能不会因为装入 WKWebView 就自动变成原生能力。";
    [self showNativeError:message];
}

- (void)showNativeError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"葫芦侠" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { self.statusLabel.text = @"本地 HTML 已加载 · 原生桥接已启用"; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { self.statusLabel.text = [NSString stringWithFormat:@"页面加载失败：%@", error.localizedDescription]; }
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    BOOL isLocalDocument = url.isFileURL || [url.absoluteString isEqualToString:@"about:blank"];
    BOOL isGeneratedSubframe = !action.targetFrame.isMainFrame && ([url.scheme isEqualToString:@"about"] || [url.scheme isEqualToString:@"data"] || [url.scheme isEqualToString:@"blob"]);
    decisionHandler((isLocalDocument || isGeneratedSubframe) ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)dealloc { [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"hx"]; }
@end
