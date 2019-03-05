//
//  ZWAop.m
//  ZWAop
//
//  Created by Wei on 2018/11/10.
//  Copyright © 2018年 Wei. All rights reserved.
//

#import "ZWAop.h"

#if defined(__arm64__)
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>

#define ZWGlobalOCSwizzleStackSize  "#0xe0"
#define ZWInvocationStackSize  "#0x60"
#define ZWAopInvocationCallStackSize "#0x30"
#define ZWAopIMPListMaxCount  1
#define ZWAopIMPListHeaderSize  16


#pragma mark - tools

typedef struct ZWToolStruct {
    void (*retain)(__unsafe_unretained id obj);
    void (*release)(__unsafe_unretained id obj);
    void (*myRetain)(__unsafe_unretained id obj);
    void (*myRelease)(__unsafe_unretained id obj);
    void (*pc)(__unsafe_unretained id o, NSString *pre);
    
    void (*lock)(void *lock);
    void (*unlock)(void *lock);
    void (*rw_rdlock)(pthread_rwlock_t *lock);
    void (*rw_wrlock)(pthread_rwlock_t *lock);
    void (*rw_unlock)(pthread_rwlock_t *lock);
} ZWToolStruct;

OS_ALWAYS_INLINE void ZWRetain() {
    asm volatile("b _objc_retain");
}
OS_ALWAYS_INLINE void ZWRelease() {
    asm volatile("b _objc_release");
}
OS_ALWAYS_INLINE void pc(__unsafe_unretained id o, NSString *pre) {
    void *p = (__bridge void *)o;
    NSLog(@"%@ %@ %p：%@",pre, o, p, [o valueForKey:@"retainCount"]);
}
OS_ALWAYS_INLINE void ZWMyRetain(uintptr_t *isa_t) {
    //    atomic_fetch_add(isa_t, (1ULL<<45));//C++原子操作，比较慢
    uintptr_t carry;//不处理溢出，内部对象不可能溢出
    *isa_t = __builtin_addcl(*isa_t,(1ULL<<45),0,&carry);
}
OS_ALWAYS_INLINE void ZWMyRelease(uintptr_t *isa_t) {
    //    atomic_fetch_sub(isa_t, (1ULL<<45));
    uintptr_t carry;
    *isa_t = __builtin_subcl(*isa_t,(1ULL<<45),0,&carry);
}

OS_ALWAYS_INLINE void ZWRWRLock(pthread_rwlock_t *lock) {
    pthread_rwlock_rdlock(lock);
}
OS_ALWAYS_INLINE void ZWRWWLock(pthread_rwlock_t *lock) {
    pthread_rwlock_wrlock(lock);
}
OS_ALWAYS_INLINE void ZWRWUnlock(pthread_rwlock_t *lock) {
    pthread_rwlock_unlock(lock);
}

OS_ALWAYS_INLINE void ZWLock(void *lock) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
    if (@available(iOS 10.0, *)) {
        os_unfair_lock_lock((os_unfair_lock_t)lock);
    }
#else
    pthread_mutex_lock(&lock);
#endif
}
OS_ALWAYS_INLINE void ZWUnlock(void *lock) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
    if (@available(iOS 10.0, *)) {
        os_unfair_lock_unlock((os_unfair_lock_t)lock);
    }
#else
    pthread_mutex_unlock(&lock);
#endif
}
ZWToolStruct ZWTools = {ZWRetain, ZWRelease, (void *)ZWMyRetain, (void *)ZWMyRelease, pc,
    ZWLock, ZWUnlock, ZWRWRLock, ZWRWWLock, ZWRWUnlock};

#pragma mark - container

static Class _ZWObjectClass;

typedef struct ZWAopIMPList {
    void *isa;
    union {
        unsigned int index;
        unsigned int count;
    };
    unsigned int maxCount;
    void **imps;
} ZWAopIMPList;

typedef struct ZWAopIMPAll {
    void *isa;
    unsigned long long frameLength;
    ZWAopIMPList *before;
    void *origin;
    ZWAopIMPList *after;
    __unsafe_unretained id replace;
} ZWAopIMPAll;


void ZWAopIMPListAdd(ZWAopIMPList **originPtr, void *imp) {
    ZWAopIMPList *origin = *originPtr;
    if (OS_EXPECT(!origin, 1)) {
        origin = malloc(ZWAopIMPListMaxCount + ZWAopIMPListHeaderSize);
        *origin = (ZWAopIMPList){(__bridge void *)_ZWObjectClass, 0, ZWAopIMPListMaxCount, NULL};
    }
    if (OS_EXPECT(origin->count > origin->maxCount - 1, 1)) {
        int orignSize = origin->maxCount * 8 + ZWAopIMPListHeaderSize;
        
        origin->maxCount = origin->maxCount * 2;
        void *new = malloc(origin->maxCount * 8 + ZWAopIMPListHeaderSize);
        memcpy(new, origin, orignSize);
        void *tmp = origin;
        origin = new;
        
        ZWTools.release((__bridge id)(tmp));
    }
    
    if (OS_EXPECT(origin->count < origin->maxCount, 1)) {
        void **p = (void **)origin;
        int index = ++(origin->index);
        p[index + 1] = imp;
        ZWTools.retain((__bridge id)imp);
    }
    
    *originPtr = origin;
}
void ZWAopIMPListRemove(ZWAopIMPList **originPtr, void *imp) {
    ZWAopIMPList *origin = *originPtr;
    if (OS_EXPECT(!origin, 0)) return;
    
    void **p = (void **)origin;
    int index = -1;
    for (int i = 0; i < origin->count; ++i) {
        if (OS_EXPECT(p[i+2] == imp, 0)) {
            index = i;
        }
    }
    if (OS_EXPECT(index != -1, 1)) {
        ZWAopIMPList *new = malloc(origin->maxCount * 8 + ZWAopIMPListHeaderSize);
        int offset = (2 + index) * 8;
        memcpy(new, origin, offset);
        memcpy((void *)new + offset, (void *)origin + offset + 8, (origin->count - index - 1) * 8);
        void *tmp = origin;
        origin = new;
        --(origin->count);
        ZWTools.release((__bridge id)(tmp));
        ZWTools.release((__bridge id)(imp));
    }
    
    *originPtr = origin;
}



ZWAopIMPAll *ZWAopIMPAllNew() {
    ZWAopIMPAll *new = malloc(sizeof(ZWAopIMPAll));
    *new = (ZWAopIMPAll){(__bridge void *)_ZWObjectClass, 0, NULL, NULL, NULL, NULL};
    return new;
};

/*  选用NSDictionary字典作为关联容器，其查询插入效率很高。使用CFDictionaryRef替代意义不大，
 CFDictionaryCreateMutable创建效率比[NSMutableDictionary dictionary]低很多，使用
 也没有NSDictionary方便，效率也高不了多少。最重要的是CFDictionaryRef也要求key和value
 为对象，所以不能使用selector作为key，只能将selector封装成NSNumber再使用，所以无法通过
 避免创建对象来降低开销，不过好消息是NSNumber创建开销较小。（在队上分配内存是比较昂贵的操作，
 特别是大量分配（万次/秒），在这里频繁调用的场景尤其明显。）
 另外：CFDictionaryGetKeysAndValues这个函数似乎有bug，拿到的key和value数组不太对。
 目前该方案一半的开销开销在字典的查询上，想要再有明显优化就需要自定义容器了。或者想要再更大
 的提升，就得从实现原理入手了。
 */
static NSMutableDictionary  *_ZWAllIMPs;
static Class _ZWBlockClass;


#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
API_AVAILABLE(ios(10.0))
static os_unfair_lock_t _ZWLock;
static pthread_rwlock_t _ZWWrLock;

#else
static pthread_mutex_t _ZWLock;
#endif

#pragma mark - constructor

__attribute__((constructor(2018))) void ZWInvocationInit() {
    
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
    if (@available(iOS 10.0, *)) {
        _ZWLock = malloc(sizeof(os_unfair_lock));
        _ZWLock->_os_unfair_lock_opaque = 0;
        pthread_rwlock_init(&_ZWWrLock, NULL);
    }
#else
    pthread_mutex_init(&_ZWLock, NULL);
#endif
    
    
    _ZWAllIMPs = [NSMutableDictionary dictionary];
    _ZWBlockClass = NSClassFromString(@"NSBlock");
    void *classPtr = (__bridge void *)([NSObject class]);
    //isa的末位表示是否是优化的指针，如果是纯指针，其会调用sidetable_retain来存储retainCount
    uintptr_t newISA = (uintptr_t)classPtr | 0x1;
    classPtr = (void *)newISA;
    _ZWObjectClass = (__bridge Class)(classPtr);
}

#pragma mark - erery invocation

OS_ALWAYS_INLINE void ZWStoreParams(void) {
    asm volatile("str    d7, [x11, #0x88]\n\
                 str    d6, [x11, #0x80]\n\
                 str    d5, [x11, #0x78]\n\
                 str    d4, [x11, #0x70]\n\
                 str    d3, [x11, #0x68]\n\
                 str    d2, [x11, #0x60]\n\
                 str    d1, [x11, #0x58]\n\
                 str    d0, [x11, #0x50]\n\
                 str    x8, [x11, #0x40]\n\
                 str    x7, [x11, #0x38]\n\
                 str    x6, [x11, #0x30]\n\
                 str    x5, [x11, #0x28]\n\
                 str    x4, [x11, #0x20]\n\
                 str    x3, [x11, #0x18]\n\
                 str    x2, [x11, #0x10]\n\
                 str    x1, [x11, #0x8]\n\
                 str    x0, [x11]\n\
                 ");
}
OS_ALWAYS_INLINE void ZWLoadParams(void) {
    asm volatile("ldr    d7, [x11, #0x88]\n\
                 ldr    d6, [x11, #0x80]\n\
                 ldr    d5, [x11, #0x78]\n\
                 ldr    d4, [x11, #0x70]\n\
                 ldr    d3, [x11, #0x68]\n\
                 ldr    d2, [x11, #0x60]\n\
                 ldr    d1, [x11, #0x58]\n\
                 ldr    d0, [x11, #0x50]\n\
                 ldr    x8, [x11, #0x40]\n\
                 ldr    x7, [x11, #0x38]\n\
                 ldr    x6, [x11, #0x30]\n\
                 ldr    x5, [x11, #0x28]\n\
                 ldr    x4, [x11, #0x20]\n\
                 ldr    x3, [x11, #0x18]\n\
                 ldr    x2, [x11, #0x10]\n\
                 ldr    x1, [x11, #0x8]\n\
                 ldr    x0, [x11]\n\
                 ");
}

OS_ALWAYS_INLINE void ZWCopyStackParams(void) {
    //x11=sp，x12=原始栈参数地址，
    asm volatile("mov    x15, sp\n"
                 "LZW_20181108:\n"
                 "cbz    x13, LZW_20181109\n"
                 "ldr    x0, [x12]\n"
                 "str    x0, [x15]\n"
                 "add    x15, x15, #0x8\n"
                 "add    x12, x12, #0x8\n"
                 "sub    x13, x13, #0x8\n"
                 "cbnz   x13, LZW_20181108\n"
                 "LZW_20181109:");
}


void ZWGlobalOCSwizzle(void) __attribute__((optnone)){
    asm volatile("stp    x29, x30, [sp, #-0x10]!");
    
    asm volatile("mov    x29, sp\n\
                 sub    sp, sp, " ZWGlobalOCSwizzleStackSize);
    
    asm volatile("mov    x11, sp");
    asm volatile("bl    _ZWStoreParams");
    
    asm volatile("mov    x0, sp");
    asm volatile("bl    _ZWBeforeInvocation");
    
    asm volatile("str    x0, [sp, #0xa0]");
    asm volatile("mov    x1, x0");
    asm volatile("mov    x0, sp");
    asm volatile("bl    _ZWInvocation");
    
    /*  存储可能的返回值。正常情况下只会用到x0，d0。但对于NSRange这种大于8Byte小于等于16Byte的整型返回值，
     则通过x0，x1返回，对于大于16Byte的整型通过x8间接寻址返回。浮点数通过d0返回，CGRect通过d0-d3返回，
     浮点数最多4个，否则也间接寻址返回。这种间接寻址不用我们操心，Xcode会将其变成指针。
     */
    asm volatile("str    x0, [sp, #0xa8]");
    asm volatile("str    x1, [sp, #0xb0]");
    asm volatile("str    x8, [sp, #0xb8]");
    asm volatile("str    d0, [sp, #0xc0]");
    asm volatile("str    d1, [sp, #0xc8]");
    asm volatile("str    d2, [sp, #0xd0]");
    asm volatile("str    d3, [sp, #0xd8]");
    
    asm volatile("ldr    x1, [sp, #0xa0]");
    asm volatile("mov    x0, sp");
    asm volatile("bl    _ZWAfterInvocation");
    
    //恢复返回值
    asm volatile("ldr    x0, [sp, #0xa8]");
    asm volatile("ldr    x1, [sp, #0xb0]");
    asm volatile("ldr    x8, [sp, #0xb8]");
    asm volatile("ldr    d0, [sp, #0xc0]");
    asm volatile("ldr    d1, [sp, #0xc8]");
    asm volatile("ldr    d2, [sp, #0xd0]");
    asm volatile("ldr    d3, [sp, #0xd8]");
    
    asm volatile("mov    sp, x29");
    asm volatile("ldp    x29, x30, [sp], #0x10");
}


OS_ALWAYS_INLINE ZWAopIMPAll *ZWGetAllImps(__unsafe_unretained id class, __unsafe_unretained id selKey) {
    
    ZWTools.rw_rdlock(&_ZWWrLock);
    __unsafe_unretained NSDictionary *dict = _ZWAllIMPs[class];
    __unsafe_unretained id invocation = dict[selKey];
    ZWTools.rw_unlock(&_ZWWrLock);
    
    return (__bridge ZWAopIMPAll *)invocation;
}

OS_ALWAYS_INLINE IMP ZWGetOriginImp(ZWAopIMPAll *allImps) {
    return allImps->origin;
}

OS_ALWAYS_INLINE IMP ZWGetReplaceImp(ZWAopIMPAll *allImps) {
    __unsafe_unretained id invocation = allImps->replace;
    if (invocation) {
        uint64_t *p = (__bridge void *)(invocation);
        return (IMP)*(p + 2);
    }
    return NULL;
}

IMP ZWGetAopImp(__unsafe_unretained id block) __attribute__((optnone)) {
    uint64_t *p = (__bridge void *)(block);
    return (IMP)*(p + 2);
}


void ZWAopInvocationCall(void **sp,
                         __unsafe_unretained id invocations,
                         ZWAopIMPAll *allImp,
                         ZWAopInfo *infoP,
                         NSUInteger frameLength) __attribute__((optnone)) {
    ZWGetAopImp(invocations);
    asm volatile("cbz    x0, LZW_20181107");
    asm volatile("mov    x17, x0");
    asm volatile("ldr    x14, %0": "=m"(infoP));
    asm volatile("ldr    x11, %0": "=m"(sp));
    asm volatile("ldr    x13, %0": "=m"(frameLength));
    asm volatile("ldr    x16, %0": "=m"(invocations));
    asm volatile("cbz    x13, LZW_20181110");
    asm volatile("add    x12, x11, " ZWGlobalOCSwizzleStackSize);
    asm volatile("add    x12, x12, 0x10");//ZWGlobalOCSwizzleStackSize + 0x10
    
    asm volatile("sub    sp, sp, x13");
    asm volatile("bl     _ZWCopyStackParams");
    asm volatile("LZW_20181110:");
    asm volatile("bl     _ZWLoadParams");
    asm volatile("mov    x1, x14");
    asm volatile("mov    x0, x16");
    asm volatile("blr    x17");
    asm volatile("sub    sp, x29, " ZWAopInvocationCallStackSize);
    asm volatile("LZW_20181107:");
}

OS_ALWAYS_INLINE ZWAopIMPAll *ZWAopInvocation(void **sp,
                                              ZWAopOption option,
                                              ZWAopIMPAll *allImpsCache) {
    __unsafe_unretained id obj = (__bridge id)(*sp);
    SEL sel = *(sp + 1);
    if (OS_EXPECT(!obj || !sel, 0)) return 0;
    __unsafe_unretained id selKey = @((NSUInteger)(void *)sel);
    
    //以前是用NSArray来作为容器，但使用结构体后，可以大幅提高性能
    ZWAopInfo info = {obj, sel, option};
    
    ZWAopIMPAll *allImps = allImpsCache ?: ZWGetAllImps(object_getClass(obj), selKey);
    if (OS_EXPECT(!allImps, 0)) return NULL;
    
    //这里最好保持一个强引用，如果在调用过程中，调用正好被移除，可能会crash。
    NSInteger flag = option & ZWAopOptionBefore;
    flag > 0 ? ZWTools.myRetain((__bridge id)(allImps)) : nil;
    
    void **imps = flag > 0 ? (void **)allImps->before : (void **)allImps->after;
    int count = imps ? ((ZWAopIMPList *)imps)->count : 0;
    
    for (int i = 0; i < count; ++i) {
        //这里也需要一个强引用
        id block = (__bridge id)(imps[i+2]);//第一二个不是imp，跳过
        if (OS_EXPECT(block != nil, 1)) {
            ZWAopInvocationCall(sp, block, allImps, &info, allImps->frameLength);
        }
    }
    flag > 0 ? nil : ZWTools.myRelease((__bridge id)(allImps));
    
    return allImps;
}

OS_ALWAYS_INLINE ZWAopIMPAll *ZWBeforeInvocation(void **sp) {
    return ZWAopInvocation(sp, ZWAopOptionBefore, NULL);
}

void ZWManualPlaceholder() __attribute__((optnone)) {}
/*  本函数关闭编译优化，如果不关闭，sp寄存器的回溯值在不同的优化情况下是不同的，还需要区分比较麻烦，
 而且即使开启优化也只有一丢丢的提升，还不如关闭图个方便。ZWManualPlaceholder占位函数，仅为触发
 Xcode插入x29, x30, [sp, #-0x10]!记录fp, lr。
 */
void ZWInvocation(void **sp, ZWAopIMPAll *allImpsCache) __attribute__((optnone)) {
    __unsafe_unretained id obj;
    SEL sel;
    void *objPtr = &obj;
    void *selPtr = &sel;
    NSUInteger frameLength = allImpsCache->frameLength;
    ZWManualPlaceholder();
    
    asm volatile("ldr    x11, %0": "=m"(sp));
    asm volatile("ldr    x10, %0": "=m"(objPtr));
    asm volatile("ldr    x0, [x11]");
    asm volatile("str    x0, [x10]");
    asm volatile("ldr    x10, %0": "=m"(selPtr));
    asm volatile("ldr    x0, [x11, #0x8]");
    asm volatile("str    x0, [x10]");
    
    //以前是用NSArray来作为容器，但使用结构体后，可以大幅提高性能
    ZWAopInfo info = {obj, sel, ZWAopOptionReplace};
    void *infoPtr = &info;
    asm volatile("ldr    x0, %0": "=m"(allImpsCache));
    asm volatile("bl     _ZWGetReplaceImp");
    asm volatile("cbz    x0, LZW_20181105");
    
    asm volatile("mov    x17, x0");
    asm volatile("ldr    x14, %0": "=m"(infoPtr));
    asm volatile("ldr    x11, %0": "=m"(sp));
    asm volatile("ldr    x13, %0": "=m"(frameLength));
    asm volatile("cbz    x13, LZW_20181111");
    asm volatile("add    x12, x11, " ZWGlobalOCSwizzleStackSize);
    asm volatile("add    x12, x12, 0x10");//ZWGlobalOCSwizzleStackSize + 0x10
    
    asm volatile("sub    sp, sp, x13");
    asm volatile("bl     _ZWCopyStackParams");
    asm volatile("LZW_20181111:");
    asm volatile("bl     _ZWLoadParams");
    asm volatile("mov    x1, x14");
    asm volatile("blr    x17");
    asm volatile("sub    sp, x29, " ZWInvocationStackSize);
    asm volatile("b      LZW_20181106");
    
    asm volatile("LZW_20181105:");
    asm volatile("ldr    x0, %0": "=m"(allImpsCache));
    asm volatile("bl     _ZWGetOriginImp");
    asm volatile("cbz   x0, LZW_20181106");
    
    asm volatile("mov    x17, x0");
    asm volatile("ldr    x11, %0": "=m"(sp));
    asm volatile("ldr    x13, %0": "=m"(frameLength));
    asm volatile("cbz    x13, LZW_20181112");
    asm volatile("add    x12, x11, " ZWGlobalOCSwizzleStackSize);
    asm volatile("add    x12, x12, 0x10");//ZWGlobalOCSwizzleStackSize + 0x10
    asm volatile("sub    sp, sp, x13");
    asm volatile("bl     _ZWCopyStackParams");
    asm volatile("LZW_20181112:");
    asm volatile("bl     _ZWLoadParams");
    asm volatile("blr    x17");
    asm volatile("sub    sp, x29, " ZWInvocationStackSize);
    asm volatile("LZW_20181106:");
}


OS_ALWAYS_INLINE void ZWAfterInvocation(void **sp, ZWAopIMPAll *allImpsCache) {
    ZWAopInvocation(sp, ZWAopOptionAfter, allImpsCache);
}

#pragma mark - register or remove

OS_ALWAYS_INLINE Method ZWGetMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method retMethod = NULL;
    Method *list = class_copyMethodList(cls, &count);
    for (int i = 0; i < count; ++i) {
        Method m = list[i];
        SEL s = method_getName(m);
        if (OS_EXPECT(sel_isEqual(s, sel), 0)) {
            retMethod = m;
        }
    }
    
    free(list);
    return retMethod;
}


id ZWAddAop(id obj, SEL sel, ZWAopOption options, id block) {
    if (OS_EXPECT(!obj || !sel || !block, 0)) return nil;
    if (OS_EXPECT(![block isKindOfClass:_ZWBlockClass], 1)) return nil;
    if (OS_EXPECT(options == ZWAopOptionOnly
                  || options == ZWAopOptionMeta
                  || options == (ZWAopOptionMeta | ZWAopOptionOnly), 0)) return nil;
    
    
    Class class = object_isClass(obj) ? obj : object_getClass(obj);
    if (OS_EXPECT(options & ZWAopOptionMeta, 0)) {
        class = class_isMetaClass(class) ? class : object_getClass(obj);
    }
    
    Method method = ZWGetMethod(class, sel);//class_getInstanceMethod(class, sel)会获取父类的方法
    
    IMP originImp = method_getImplementation(method);
    if (!originImp) {
        NSLog(@"ZWAop: Can not find '%s' in class '%@'.", sel_getName(sel), class);
        return nil;
    }
    
    NSNumber *selKey = @((NSUInteger)(void *)sel);
    NSMutableDictionary *originImps = nil;
    
    ZWTools.rw_wrlock(&_ZWWrLock);
    
    if (OS_EXPECT(!_ZWAllIMPs[(id<NSCopying>)class], 0)) {
        originImps = [NSMutableDictionary dictionary];
        _ZWAllIMPs[(id<NSCopying>)class] = originImps;
    } else {
        originImps = _ZWAllIMPs[(id<NSCopying>)class];
    }
    
    ZWAopIMPAll *allImps = (__bridge ZWAopIMPAll *)(originImps[selKey]);
    
    if (OS_EXPECT(!allImps, 1)) {
        allImps = ZWAopIMPAllNew();
        originImps[selKey] = (__bridge id)allImps;
        ZWTools.release((__bridge id)allImps);
    }
    
    if (method_getNumberOfArguments(method) > 5) {//优化点：自定义预估函数
        const char *type = method_getTypeEncoding(method);
        NSMethodSignature *sign = [NSMethodSignature signatureWithObjCTypes:type];
        allImps->frameLength = [sign frameLength] - 0xe0;
    }
    
    if (OS_EXPECT(originImp != ZWGlobalOCSwizzle, 1)) {
        allImps->origin = originImp;
    }
    if (options & ZWAopOptionReplace) {
        allImps->replace = block;
        ZWTools.retain(block);
    }
    
    if (options & ZWAopOptionBefore) {
        ZWAopIMPListAdd(&(allImps->before), (__bridge void *)(block));
    }
    if (options & ZWAopOptionAfter) {
        ZWAopIMPListAdd(&(allImps->after), (__bridge void *)(block));
    }
    
    ZWTools.rw_unlock(&_ZWWrLock);
    method_setImplementation(method, ZWGlobalOCSwizzle);
    
    return block;
}

OS_ALWAYS_INLINE void ZWRemoveInvocation(__unsafe_unretained Class class,
                                         __unsafe_unretained id identifier,
                                         ZWAopOption options) {
    
    NSMutableDictionary *invocations = _ZWAllIMPs[(id<NSCopying>)class];
    NSArray *allKeys = [invocations allKeys];
    
    for (NSNumber *key in allKeys) {
        __unsafe_unretained id obj = invocations[key];
        ZWAopIMPAll *allImps = (__bridge ZWAopIMPAll *)obj;
        if (options & ZWAopOptionReplace) {
            allImps->replace = nil;
        }
        
        if (options & ZWAopOptionBefore) {
            ZWAopIMPListRemove(&(allImps->before), (__bridge void *)(identifier));
        }
        if (options & ZWAopOptionAfter) {
            ZWAopIMPListRemove(&(allImps->after), (__bridge void *)(identifier));
        }
        if (!(allImps->replace)
            && allImps->before->count == 0
            && allImps->after->count == 0) {
            //如果没有任何AOP可以还原
        }
    }
}

void ZWRemoveAop(id obj, id identifier, ZWAopOption options) {
    if (OS_EXPECT(!obj, 0)) return;
    
    Class class = object_isClass(obj) ? obj : object_getClass(obj);
    if (OS_EXPECT(options & ZWAopOptionMeta, 0)) {
        class = class_isMetaClass(class) ? class : object_getClass(obj);
    }
    
    ZWTools.rw_wrlock(&_ZWWrLock);
    ZWRemoveInvocation(class, identifier, options);
    ZWTools.rw_unlock(&_ZWWrLock);
}

#pragma mark - convenient api

id ZWAddAopBefore(id obj, SEL sel, id block) {
    return ZWAddAop(obj, sel, ZWAopOptionBefore, block);
}
id ZWAddAopAfter(id obj, SEL sel, id block) {
    return ZWAddAop(obj, sel, ZWAopOptionAfter, block);
}
id ZWAddAopReplace(id obj, SEL sel, id block) {
    return ZWAddAop(obj, sel, ZWAopOptionReplace, block);
}

id ZWAddAopBeforeAndAfter(id obj, SEL sel, id block) {
    return ZWAddAop(obj, sel, ZWAopOptionBefore | ZWAopOptionAfter, block);
}
id ZWAddAopAll(id obj, SEL sel, id block) {
    return ZWAddAop(obj, sel, ZWAopOptionAll, block);
}

void ZWRemoveAopClass(id obj, ZWAopOption options) {
    return ZWRemoveAop(obj, nil, options);
}
void ZWRemoveAopClassMethod(id obj, id identifier, ZWAopOption options) {
    return ZWRemoveAop(obj, identifier, options | ZWAopOptionRemoveAop);
}

#else
#pragma mark - placeholder
id ZWAddAop(id obj, SEL sel, ZWAopOption options, id block) {}
void ZWRemoveAop(id obj, id identifier, ZWAopOption options) {}
id ZWAddAopBefore(id obj, SEL sel, id block){}
id ZWAddAopAfter(id obj, SEL sel, id block){}
id ZWAddAopReplace(id obj, SEL sel, id block){}
id ZWAddAopBeforeAndAfter(id obj, SEL sel, id block){}
id ZWAddAopAll(id obj, SEL sel, id block){}
void ZWRemoveAopClassMethod(id obj, id identifier, ZWAopOption options){}
void ZWRemoveAopClass(id obj, ZWAopOption options){}
#endif
