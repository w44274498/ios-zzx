//
//  protractorView.h
//  TakeVedio
//
//  Created by 莞尔一念 on 13/09/2017.
//  Copyright © 2017 jessica. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "protractorLayer.h"
#import "UIView+Resize.h"

@interface myProtractorView : UIView

@property (nonatomic, copy) void (^callback)(CGFloat from, CGFloat to, CGFloat angle);

// 量角器层
@property (nonatomic, strong) myProtractorLayer *myProtractorLayer;   // 量角器层
@property (nonatomic, assign) CGFloat touch_begin_angle;            // 触摸起始角度
@property (nonatomic, assign) BOOL touch_min;                       // 是否修改小角线
@property (nonatomic, assign) BOOL touch_direct_determined;         // 是否确定修改夹角
@property (nonatomic, assign) CGFloat layer_start_angle;            // 原始起始角
@property (nonatomic, assign) CGFloat layer_end_angle;              // 原始终止角

// 触摸控制层
//@property (nonatomic, strong) UIButton *touchTypeButton;            // 触摸类型控制按钮
@property (nonatomic, assign) BOOL change_protractor_angle;         // 是否改变量角器的角度
@property (nonatomic, assign) BOOL move_protractor;                 //是否移动量角器
@property (nonatomic, assign) CGPoint touch_begin_point;            // 触摸开始位置
@property (nonatomic, assign) CGPoint layer_point;                  // 触摸开始时图片位置

- (instancetype)initWithFrame:(CGRect)frame;

@end


