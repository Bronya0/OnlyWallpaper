#ifndef BRIDGE_H
#define BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// 初始化壁纸（返回 0 成功，-1 失败）
int InitWallpaper(const char *videoPath, const char *htmlTemplate);

// 暂停/恢复视频
void PauseWallpaper();
void ResumeWallpaper();

// 检查视频是否暂停
int IsVideoPaused();

// 退出清理（自动调用）
void CleanupWallpaper();

// 停止应用循环
void StopApp();

// 运行主事件循环（阻塞）
void RunApp();

#ifdef __cplusplus
}
#endif

#endif