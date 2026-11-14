#import "MCPServer.h"
#import "IOSMCPPreferences.h"
#import <UIKit/UIKit.h>

static void dshpc_start(void) {
    MCPServer *server = [MCPServer sharedInstance];
    uint16_t port = IOSMCPConfiguredPort();
    if (server.isRunning && server.port == port) return;
    [server startOnPort:port];
}

__attribute__((constructor)) static void dshpc_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ dshpc_start(); });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) { dshpc_start(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) { dshpc_start(); }];
}
