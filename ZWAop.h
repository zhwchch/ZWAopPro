//
//  ZWAop.h
//  ZWAop
//
//  Created by Wei on 2018/11/10.
//  Copyright © 2018年 Wei. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSInteger, ZWAopOption) {
    ZWAopOptionReplace = 1,
    ZWAopOptionBefore = 1 << 1,
    ZWAopOptionAfter = 1 << 2,
    ZWAopOptionBeforeAfter = ZWAopOptionBefore | ZWAopOptionAfter,
    ZWAopOptionAll = ZWAopOptionReplace | ZWAopOptionBefore | ZWAopOptionAfter,
    
    //以下option只能与上面的混合使用，不能单独使用
    ZWAopOptionOnly = 1 << 11,
    ZWAopOptionMeta = 1 << 12,
    ZWAopOptionRemoveAop = 1 << 13,
};
typedef struct ZWAopInfo {
    __unsafe_unretained id obj;
    SEL sel;
    ZWAopOption opt;
} ZWAopInfo;

#ifdef __cplusplus
extern "C" {
#endif
    
    /*  obj可以传对象也可以传class，如果添加元类AOP，option增加ZWAopOptionMeta，
     option可以通过组合传递来一次性添加多个切面，其会返回一个identifier，实际上就是block
     */
    id ZWAddAop(id obj, SEL sel, ZWAopOption options, id block);
    /*  移除的时候需要将该identifier作为参数来搜索，复合ZWAopOptionRemoveAop，将会移除
     Method对应的所有切面调用。需要注意的是，如果多个Method共用一个切面，将移除所有。
     */
    void ZWRemoveAop(id obj, id identifier, ZWAopOption options);
    
    
    
    
    //convenient api as follows
    id ZWAddAopBefore(id obj, SEL sel, id block);
    id ZWAddAopAfter(id obj, SEL sel, id block);
    id ZWAddAopReplace(id obj, SEL sel, id block);
    id ZWAddAopBeforeAndAfter(id obj, SEL sel, id block);
    id ZWAddAopAll(id obj, SEL sel, id block);
    
    //移除Class-Method-Aop注入的所有切面调用，identifier用于搜索对应的Method
    void ZWRemoveAopClassMethod(id obj, id identifier, ZWAopOption options);
    //移除Class-Aop所有的切面调用
    void ZWRemoveAopClass(id obj, ZWAopOption options);
    
#ifdef __cplusplus
} // extern "C"
#endif
