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

#define ZWGlobalOCSwizzleStackSize  "#0xe0"
#define ZWInvocationStackSize  "#0x60"
#define ZWAopInvocationCallStackSize "#0x30"
#define ZWAopImpsMaxCount  1
#define ZWAopImpsHeaderSize  24
#define ZWAopImpsHeaderCount  ZWAopImpsHeaderSize/8
#define ZWMemeryBarrer()  asm volatile("dmb ish")



#pragma mark - tools

typedef struct ZWToolStruct {
    void (*retain)(__unsafe_unretained id obj);
    void (*release)(__unsafe_unretained id obj);
    void (*pc)(__unsafe_unretained id o, NSString *pre);
    
    void (*rwReadLock)(pthread_rwlock_t *lock);
    void (*rwWriteLock)(pthread_rwlock_t *lock);
    void (*rwUnlock)(pthread_rwlock_t *lock);
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

OS_ALWAYS_INLINE void ZWRWRLock(pthread_rwlock_t *lock) {
    pthread_rwlock_rdlock(lock);
}
OS_ALWAYS_INLINE void ZWRWWLock(pthread_rwlock_t *lock) {
    pthread_rwlock_wrlock(lock);
}
OS_ALWAYS_INLINE void ZWRWUnlock(pthread_rwlock_t *lock) {
    pthread_rwlock_unlock(lock);
}


ZWToolStruct ZWTools = {ZWRetain, ZWRelease, pc,
    ZWRWRLock, ZWRWWLock, ZWRWUnlock};

#pragma mark - container

static Class _ZWObjectClass;

/*  定义OC拟对象，通过malloc分配内存，然后初始化isa指针达到类似于OC对象的效果，
 这种对象可以直接放入字典，也可以使用MRC管理，同时还可以被ARC管理。能够减少
 对象创建和销毁的消耗，同时减少retain+release的次数。
 */


typedef struct ZWAopImps {
    void *isa;
    union {
        unsigned int index;
        unsigned int count;
    };
    unsigned int maxCount;
    long long only;
    void **imps;
} ZWAopImps;

typedef struct ZWAopInfo {
    void *isa;
    unsigned long long frameLength;
    ZWAopImps *before;
    void *origin;
    ZWAopImps *after;
    __unsafe_unretained id replace;
} ZWAopInfo;


ZWAopInfo *ZWAopInfoNew() {
    ZWAopInfo *new = malloc(sizeof(ZWAopInfo));
    *new = (ZWAopInfo){(__bridge void *)_ZWObjectClass, 0, NULL, NULL, NULL, NULL};
    return new;
};




ZWAopImps *ZWAopImpsNew(ZWAopImps *aopImps, int count) {
    if (count <= 0) {
        count = aopImps->maxCount * 2;
    }
    ZWAopImps *newSpace = (ZWAopImps *)malloc(count * 8 + ZWAopImpsHeaderSize);
    *newSpace = (ZWAopImps){(__bridge void *)_ZWObjectClass, 0, count, 0, NULL};
    return newSpace;
}

void ZWAopImpsCopy(ZWAopImps *aopImps, ZWAopImps *copy, int index) {
    int count = copy->maxCount;
    if (index < 0) {
        memcpy(copy, aopImps, aopImps->maxCount * 8 + ZWAopImpsHeaderSize);
    } else {
        int offset = (ZWAopImpsHeaderCount + index) * 8;
        memcpy(copy, aopImps, offset);
        memcpy((void *)copy + offset, (void *)aopImps + offset + 8, (aopImps->count - index - 1) * 8);
    }
    copy->maxCount = count;
}

/*  设计使用类似于RCU的机制，读取不加锁，写加锁（由外部加锁），写时先将原数据做拷贝，
 再修改拷贝，最后替换原始数据指针。这种机制下，原始数据需要延迟释放，所以十分依赖
 retainCount机制。此机制适合读远多于写，而且拷贝开销并不算太大的情况。
 */
void ZWAopImpsAdd(ZWAopImps **aopImpsPtr, void *block, BOOL only) {
    ZWAopImps *aopImps = *aopImpsPtr;
    if (OS_EXPECT(!aopImps, 1)) {
        aopImps = ZWAopImpsNew(NULL, ZWAopImpsMaxCount);
    }
    if (aopImps->only) {
        NSLog(@"ZWAop: Can not add this only-aop, because an only-aop is already in the list.");
        return;
    }
    
    void *tmp = NULL;
    if (only && aopImps->count > 0) {
        ZWAopImps *newAops = ZWAopImpsNew(NULL, ZWAopImpsMaxCount);
        tmp = aopImps;
        aopImps = newAops;
    } else if (OS_EXPECT(aopImps->count > aopImps->maxCount - 1, 1)) {
        void *newAops = ZWAopImpsNew(aopImps, 0);
        ZWAopImpsCopy(aopImps, newAops, -1);
        
        tmp = aopImps;
        aopImps = newAops;
    }
    
    if (OS_EXPECT(aopImps->count < aopImps->maxCount, 1)) {
        void **p = (void **)aopImps;
        int index = ++ (aopImps->index);
        p[index + ZWAopImpsHeaderCount - 1] = block;
        p[ZWAopImpsHeaderCount - 1] = (void *)(unsigned long long)(only ? 1 : 0);
        ZWTools.retain((__bridge id)block);
    }
    //内存屏障技术，保证originPtr被替换之前，origin数据已经写入完成。
    ZWMemeryBarrer();
    
    *aopImpsPtr = aopImps;
    ZWTools.release((__bridge id)(tmp));
}

void ZWAopImpsRemove(ZWAopImps **aopImpsPtr, void *block) {
    ZWAopImps *aopImps = *aopImpsPtr;
    if (OS_EXPECT(!aopImps, 0)) return;
    
    void **p = (void **)aopImps;
    int index = -1;
    for (int i = 0; i < aopImps->count; ++i) {
        if (OS_EXPECT(p[i + ZWAopImpsHeaderCount] == block, 0)) {
            index = i;
            /*  如果在ZWAopInvocation中，拿到了count，但还没有进入for循序，没有拿到block(imp)，
             但调用了本函数，删除了对应的block(imp)，此后再进入for循序，则会crash，所以这里将其值
             改为NULL，这样保证for循序中不会拿到已经释放的block(imp)指针。
             */
            p[i + ZWAopImpsHeaderCount] = NULL;
        }
    }
    
    void *tmp = NULL;
    
    if (OS_EXPECT(index != -1, 1)) {
        void *newAops = ZWAopImpsNew(aopImps, 0);
        ZWAopImpsCopy(aopImps, newAops, index);
        
        tmp = aopImps;
        aopImps = newAops;
        -- (aopImps->count);
    }
    ZWMemeryBarrer();
    
    *aopImpsPtr = aopImps;
    
    ZWTools.release((__bridge id)(tmp));
    ZWTools.release((__bridge id)(block));
}

void ZWAopImpsRemoveAll(ZWAopImps **aopImpsPtr) {
    void *tmp = NULL;
    ZWAopImps *newAops = ZWAopImpsNew(*aopImpsPtr, ZWAopImpsMaxCount);
    tmp = *aopImpsPtr;
    
    ZWMemeryBarrer();
    *aopImpsPtr = newAops;
    
    ZWTools.release((__bridge id)(tmp));
}



/*  选用NSDictionary字典作为关联容器，其查询插入效率很高。使用CFDictionaryRef替代意义不大，
 CFDictionaryCreateMutable创建效率比[NSMutableDictionary dictionary]低很多，使用
 也没有NSDictionary方便，效率也高不了多少。最重要的是CFDictionaryRef也要求key和value
 为对象，所以不能使用selector作为key，只能将selector封装成NSNumber再使用，所以无法通过
 避免创建对象来降低开销，不过好消息是NSNumber创建开销较小。（在堆上分配内存是比较昂贵的操作，
 特别是大量分配（万次/秒），在这里频繁调用的场景尤其明显。）
 另外：CFDictionaryGetKeysAndValues这个函数似乎有bug，拿到的key和value数组不太对。
 目前该方案一半的开销开销在字典的查询上，想要再有明显优化就需要自定义容器了。或者想要再更大
 的提升，就得从实现原理入手了。
 */
static NSMutableDictionary  *_ZWAllInfo;
static Class _ZWBlockClass;
static pthread_rwlock_t _ZWWrLock;


#pragma mark - constructor

__attribute__((constructor(2018))) void ZWInvocationInit() {
    pthread_rwlock_init(&_ZWWrLock, NULL);
    
    _ZWAllInfo = [NSMutableDictionary dictionary];
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

/*  本函数占性能开销的66%，-_-!!!
 两次hash和取值占45%，加解锁占18%
 */
OS_ALWAYS_INLINE ZWAopInfo *ZWGetAopInfo(__unsafe_unretained id class, __unsafe_unretained id selKey) {
    
    ZWTools.rwReadLock(&_ZWWrLock);
    __unsafe_unretained NSDictionary *dict = _ZWAllInfo[class];
    __unsafe_unretained id invocation = dict[selKey];
    ZWTools.rwUnlock(&_ZWWrLock);
    
    return (__bridge ZWAopInfo *)invocation;
}

OS_ALWAYS_INLINE IMP ZWGetOriginImp(ZWAopInfo *info) {
    return info->origin;
}

OS_ALWAYS_INLINE IMP ZWGetReplaceImp(ZWAopInfo *info) {
    __unsafe_unretained id invocation = info->replace;
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
                         ZWAopInfo *info,
                         ZWAopInvocationInfo *invocationInfoP,
                         NSUInteger frameLength) __attribute__((optnone)) {
    ZWGetAopImp(invocations);
    asm volatile("cbz    x0, LZW_20181107");
    asm volatile("mov    x17, x0");
    asm volatile("ldr    x14, %0": "=m"(invocationInfoP));
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

OS_ALWAYS_INLINE ZWAopInfo *ZWAopInvocation(void **sp,
                                            ZWAopOption option,
                                            ZWAopInfo *infoCache) {
    __unsafe_unretained id obj = (__bridge id)(*sp);
    SEL sel = *(sp + 1);
    if (OS_EXPECT(!obj || !sel, 0)) return 0;
    __unsafe_unretained id selKey = @((NSUInteger)(void *)sel);
    
    //以前是用NSArray来作为容器，但使用结构体后，可以大幅提高性能
    ZWAopInvocationInfo invokeInfo = {obj, sel, option};
    
    //ZWAopImpAll分配之后不会被回收，即使所以的AOP都被删除，也不会被回收，所以也就不需要retain和release
    ZWAopInfo *info = infoCache ?: ZWGetAopInfo(object_getClass(obj), selKey);
    if (OS_EXPECT(!info, 0)) return NULL;
    
    NSInteger flag = option & ZWAopOptionBefore;
    void **imps = NULL;
    
    /*  before和after是ZWAopImps，其使用RCU机制，添加删除列表中元素，减少加锁的情况，
     使用before和after列表，需要retain来保证调用过程中，原列表被替换时，不会立即被释放，
     当然这里也可以利用ARC来管理imps。
     */
    if (flag == ZWAopOptionBefore) {
        ZWTools.retain((__bridge id)info->before);
        imps = (void **)info->before;
    } else {
        ZWTools.retain((__bridge id)info->after);
        imps = (void **)info->after;
    }
    
    int count = imps ? ((ZWAopImps *)imps)->count : 0;
    
    for (int i = 0; i < count; ++i) {
        //这里也需要一个强引用
        id block = (__bridge id)(imps[i+ZWAopImpsHeaderCount]);//第一二三个不是imp，跳过
        if (OS_EXPECT(block != nil, 1)) {
            ZWAopInvocationCall(sp, block, info, &invokeInfo, info->frameLength);
        }
    }
    if (flag == ZWAopOptionBefore) {
        ZWTools.release((__bridge id)info->before);
    } else {
        ZWTools.release((__bridge id)info->after);
    }
    
    return info;
}

OS_ALWAYS_INLINE ZWAopInfo *ZWBeforeInvocation(void **sp) {
    return ZWAopInvocation(sp, ZWAopOptionBefore, NULL);
}

void ZWManualPlaceholder() __attribute__((optnone)) {}
/*  本函数关闭编译优化，如果不关闭，sp寄存器的回溯值在不同的优化情况下是不同的，还需要区分比较麻烦，
 而且即使开启优化也只有一丢丢的提升，还不如关闭图个方便。ZWManualPlaceholder占位函数，仅为触发
 Xcode插入x29, x30, [sp, #-0x10]!记录fp, lr。
 */
void ZWInvocation(void **sp, ZWAopInfo *infoCache) __attribute__((optnone)) {
    __unsafe_unretained id obj;
    SEL sel;
    void *objPtr = &obj;
    void *selPtr = &sel;
    NSUInteger frameLength = infoCache->frameLength;
    ZWManualPlaceholder();
    
    asm volatile("ldr    x11, %0": "=m"(sp));
    asm volatile("ldr    x10, %0": "=m"(objPtr));
    asm volatile("ldr    x0, [x11]");
    asm volatile("str    x0, [x10]");
    asm volatile("ldr    x10, %0": "=m"(selPtr));
    asm volatile("ldr    x0, [x11, #0x8]");
    asm volatile("str    x0, [x10]");
    
    //以前是用NSArray来作为容器，但使用结构体后，可以大幅提高性能
    ZWAopInvocationInfo invocationInfo = {obj, sel, ZWAopOptionReplace};
    void *invocationInfoPtr = &invocationInfo;
    asm volatile("ldr    x0, %0": "=m"(infoCache));
    asm volatile("bl     _ZWGetReplaceImp");
    asm volatile("cbz    x0, LZW_20181105");
    
    asm volatile("mov    x17, x0");
    asm volatile("ldr    x14, %0": "=m"(invocationInfoPtr));
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
    asm volatile("ldr    x0, %0": "=m"(infoCache));
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


OS_ALWAYS_INLINE void ZWAfterInvocation(void **sp, ZWAopInfo *infoCache) {
    ZWAopInvocation(sp, ZWAopOptionAfter, infoCache);
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

int ZWGetParamSubUnit(const char *type, char end) {
    int level = 0;
    const char *head = type;
    
    while (*type) {
        if (!*type || (!level && (*type == end)))
            return (int)(type - head);
        
        switch (*type) {
            case ']': case '}': case ')': level--; break;
            case '[': case '{': case '(': level += 1; break;
        }
        
        type += 1;
    }
    
    return 0;
}
//根据签名获取下一个参数
const char *ZWGetParamUnit(const char *type,
                           unsigned *intSizePtr,
                           unsigned *floatSizePtr,
                           BOOL *recalculate) {
    while (1) {
        switch (*type++) {
            case 'O':
            case 'n':
            case 'o':
            case 'N':
            case 'r':
            case 'V':
                break;
                
            case '@':
                if (type[0] == '?') type++;
                if (intSizePtr) (*intSizePtr) += 8;
                return type;
                
                //遇到以下三种类型，都认为需要使用NSMethodSignature重写计算frameLength的大小
            case '[':
                while ((*type >= '0') && (*type <= '9')) type += 1;
                if (recalculate) *recalculate = YES;
                return type + ZWGetParamSubUnit(type, ']') + 1;
                
            case '{':
                if (recalculate) *recalculate = YES;
                return type + ZWGetParamSubUnit(type, '}') + 1;
                
            case '(':
                if (recalculate) *recalculate = YES;
                return type + ZWGetParamSubUnit(type, ')') + 1;
                
            case 'f':
            case 'd': if (floatSizePtr) (*floatSizePtr) += 8;; return type;
            default: if (intSizePtr) (*intSizePtr) += 8;; return type;
        }
    }
}
//参考objc的method_getNumberOfArguments
BOOL ZWIsNeedRecalculate(const char *type) {
    unsigned intSize = 0;
    unsigned floatSize = 0;
    
    //跳过返回值类型
    type = ZWGetParamUnit(type, NULL, NULL, NULL);
    while ((*type >= '0') && (*type <= '9')) type += 1;
    
    while (*type) {
        BOOL recalculate;
        type = ZWGetParamUnit(type, &intSize, &floatSize, &recalculate);
        if (OS_EXPECT(recalculate, 0)) return recalculate;
        
        while ((*type >= '0') && (*type <= '9')) type += 1;
    }
    
    //分别大概计算寄存器参数大小和浮点寄存器参数大小
    if (OS_EXPECT(intSize > 64 || floatSize > 64, 0)) return YES;
    return NO;
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
    
    ZWTools.rwWriteLock(&_ZWWrLock);
    
    //取出class对应的调用，否则初始化容器
    if (OS_EXPECT(!_ZWAllInfo[(id<NSCopying>)class], 0)) {
        originImps = [NSMutableDictionary dictionary];
        _ZWAllInfo[(id<NSCopying>)class] = originImps;
    } else {
        originImps = _ZWAllInfo[(id<NSCopying>)class];
    }
    
    //取出对应selector的调用实例ZWAopImpAll，如果不存在就创建一个新实例同时存入容器，再release一次
    ZWAopInfo *info = (__bridge ZWAopInfo *)(originImps[selKey]);
    
    if (OS_EXPECT(!info, 1)) {
        info = ZWAopInfoNew();
        originImps[selKey] = (__bridge id)info;
        ZWTools.release((__bridge id)info);
    }
    
    //计算栈参大小，即frameLength的大小，先用预估函数ZWIsNeedRecalculate估算大小，
    //如果肯定没有栈参，则frameLength=0，否则再调用NSMethodSignature计算准确栈参大小
    const char *type = method_getTypeEncoding(method);
    if (ZWIsNeedRecalculate(type)) {
        NSMethodSignature *sign = [NSMethodSignature signatureWithObjCTypes:type];
        info->frameLength = [sign frameLength] - 0xe0;
    } else {
        info->frameLength = 0;
    }
    
    //设置原始调用，替换调用，前切面和后切面值
    if (OS_EXPECT(originImp != ZWGlobalOCSwizzle, 1)) {
        info->origin = originImp;
    }
    if (options & ZWAopOptionReplace) {
        info->replace = block;
        ZWTools.retain(block);
    }
    
    if (options & ZWAopOptionBefore) {
        ZWAopImpsAdd(&(info->before), (__bridge void *)(block), (options & ZWAopOptionOnly));
    }
    if (options & ZWAopOptionAfter) {
        ZWAopImpsAdd(&(info->after), (__bridge void *)(block), (options & ZWAopOptionOnly));
    }
    
    ZWTools.rwUnlock(&_ZWWrLock);
    method_setImplementation(method, ZWGlobalOCSwizzle);
    
    return block;
}

OS_ALWAYS_INLINE void ZWRemoveInvocation(__unsafe_unretained Class class,
                                         __unsafe_unretained id identifier,
                                         ZWAopOption options) {
    
    NSMutableDictionary *invocations = _ZWAllInfo[(id<NSCopying>)class];
    NSArray *allKeys = [invocations allKeys];
    
    for (NSNumber *key in allKeys) {
        __unsafe_unretained id obj = invocations[key];
        ZWAopInfo *info = (__bridge ZWAopInfo *)obj;
        if (options & ZWAopOptionReplace) {
            if (identifier == info->replace) {
                info->replace = nil;
                ZWTools.release(identifier);
            }
        }
        
        if (options & ZWAopOptionBefore) {
            (options & ZWAopOptionRemoveAop) ? ZWAopImpsRemoveAll(&(info->before))
            : ZWAopImpsRemove(&(info->before), (__bridge void *)(identifier));
        }
        if (options & ZWAopOptionAfter) {
            (options & ZWAopOptionRemoveAop) ? ZWAopImpsRemoveAll(&(info->after))
            : ZWAopImpsRemove(&(info->after), (__bridge void *)(identifier));
        }
        if (!(info->replace)
            && info->before
            && info->after
            && info->before->count == 0
            && info->after->count == 0) {
            //如果没有任何AOP可以还原
            SEL sel = (SEL)[key unsignedLongLongValue];
            Method method = ZWGetMethod(class, sel);//class_getInstanceMethod(class, sel)会获取父类的方法
            IMP imp = method_getImplementation(method);
            if (imp == ZWGlobalOCSwizzle) {
                method_setImplementation(method, info->origin);
            }
        }
    }
}

void ZWRemoveAop(id obj, id identifier, ZWAopOption options) {
    if (OS_EXPECT(!obj, 0)) return;
    
    Class class = object_isClass(obj) ? obj : object_getClass(obj);
    if (OS_EXPECT(options & ZWAopOptionMeta, 0)) {
        class = class_isMetaClass(class) ? class : object_getClass(obj);
    }
    
    ZWTools.rwWriteLock(&_ZWWrLock);
    ZWRemoveInvocation(class, identifier, options);
    ZWTools.rwUnlock(&_ZWWrLock);
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
