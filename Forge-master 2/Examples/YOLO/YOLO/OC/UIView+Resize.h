//
//  UIViewExtension.h
//  TakeVedio
//
//  Created by 莞尔一念 on 2017/5/16.
//  Copyright © 2017年 jessica. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface UIView(Resize)

//x坐标
@property(nonatomic,assign) CGFloat x;
//y坐标
@property(nonatomic,assign) CGFloat y;
//宽度
@property(nonatomic,assign) CGFloat width;
//高度
@property(nonatomic,assign) CGFloat height;
//大小
@property(nonatomic,assign) CGSize size;
//位置
@property(nonatomic,assign) CGPoint origin;
//中心点x
@property(nonatomic,assign) CGFloat centerX;
//中心点y
@property(nonatomic,assign) CGFloat centerY;
//底部
@property(nonatomic,assign) CGFloat bottom;

@end

