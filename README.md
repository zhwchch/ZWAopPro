

# ZWAop
类似于Aspect的库，但可以添加多个切面，使用汇编完成参数传递和函数调用，效率较高，但只支持arm64。
详细实现原理请参阅：
[*任意方法的Swizzle的应用之一AOP*](https://www.jianshu.com/p/0eb7238326f5)
[*任意方法的Swizzle的应用之一AOP(续)*](https://www.jianshu.com/p/171831aed088)
注：ZWAop本来只是我写JOBridge时顺便做的一个扩展demo，但后来想了想AOP也是常见需求，所以完善了一下封装成可用的库。有兴趣者可参阅
[*JOBridge之一任意方法的Swizzle*](https://www.jianshu.com/p/905e06eeda7b)


# ZWAopPro
在ZWAop基础上通过一些非常规的手段高度优化的版本，效率较ZWAop有数倍提高，较Aspect提高大约100倍。在极致性能需求时可以使用。

# 用法
```objective-c

- (void)viewDidLoad {
    [super viewDidLoad];
	//前
    ZWAddAop(self, @selector(aMethod1:), ZWAopOptionBefore, ^(NSArray *info, int a){
        NSLog(@"before1 : %d", a);
    });
	//后
    ZWAddAop(self, @selector(aMethod2::::::::), ZWAopOptionAfter, ^(NSArray *info, NSString *str ,NSString *a2 ,NSString *a3 ,NSString *a4 ,NSString *a5 ,NSString *a6 ,NSString *a7 ,NSString *a8){
        NSLog(@"after2: %@\n%@\n%@\n%@\n%@", str, a5, a6, a7, a8);
    });
	//替换
    ZWAddAop(self, @selector(aMethod2::::::::), ZWAopOptionReplace, ^(NSArray *info, NSString *str,NSString *a2 ,NSString *a3 ,NSString *a4 ,NSString *a5 ,NSString *a6 ,NSString *a7 ,NSString *a8){
        NSLog(@"replace2: %@\n%@\n%@\n%@\n%@", str, a5, a6, a7, a8);
    });
	//前/后/替换
    ZWAddAop(self, @selector(aMethod3::), ZWAopOptionBefore | ZWAopOptionAfter| ZWAopOptionReplace, ^int (NSArray *info, NSString *str){
        NSLog(@"before3 | After3 | replace3: %@", str);
        return 11034;
    });
	//删除
    id handle1 = ZWAddAop(self, @selector(aMethod3::), ZWAopOptionAfter, ^int (NSArray *info, NSString *str){
        NSLog(@"after32: %@", str);
        return 11034;
    });
    ZWRemoveAop(self, handle1, ZWAopOptionAfter | ZWAopOptionRemoveAop);
//    ZWRemoveAop(self, nil, ZWAopOptionAfter);
	//后Aop+only，只有当前Aop会生效，更早的Aop会被删除
    ZWAddAop(self, @selector(aMethod3::), ZWAopOptionAfter | ZWAopOptionOnly, ^int (NSArray *info, NSString *str, NSArray *ar){
        NSLog(@"after33: %@", str);
        return 11034;
    });
	//类方法
    ZWAddAop([self class], @selector(aMethod4:), ZWAopOptionReplace, ^(id info , int a, int b){
        NSLog(@"META replace4:");
    });
	//大于8个参数的基础类型参数
    ZWAddAop(self, @selector(aMethod4::::::::), ZWAopOptionAfter, ^int (NSArray *info,NSInteger str, NSInteger a2,  NSInteger a3, NSInteger a4, NSInteger a5, NSInteger a6, NSInteger a7, NSInteger a8){
        NSLog(@"after43: %ld %ld %ld %ld %ld",str, a5, a6, a7, a8);
        return 11034;
    });


    //调用
    [self aMethod1:8848];
    [self aMethod2:@"test str" :@"this is a test" :@"this is a test":@"this is a test":@"this is a test":@"this is a test":@"this is a test a7":@"this is a test a8"];
    int r = [self aMethod3:@"你咋不上天呢" :@[@1,@2]];
    NSLog(@"%d",r);

    [ViewController aMethod4:12358];
    [self aMethod4:1 :2 :3 :4 :5 :6 :7 :8];

}

- (NSRange)aMethod1:(int)a {
    NSLog(@"method1: %d",a);
    return (NSRange){0,1};
}

- (void)aMethod2:(NSString *)str :(NSString *)a2 :(NSString *)a3 :(NSString *)a4 :(NSString *)a5 :(NSString *)a6 :(NSString *)a7 :(NSString *)a8 {
    NSLog(@"method2: %@\n%@\n%@\n%@\n%@", str, a5, a6, a7, a8);
}

- (int )aMethod3:(NSString *)str :(NSArray *)array{
    NSLog(@"method3: %@", str);
    return 11;
}

+ (void)aMethod4:(int )obj {
    NSLog(@"method4: %d", obj);
}

- (void)aMethod4:(NSInteger)str :(NSInteger)a2 :(NSInteger)a3 :(NSInteger)a4 :(NSInteger)a5 :(NSInteger)a6 :(NSInteger)a7 :(NSInteger)a8 {
    NSLog(@"method4: %ld %ld %ld %ld %ld",str, a5, a6, a7, a8);
}

```
