/*
 Copyright (c) 2016-2017 M.I. Hollemans
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to
 deal in the Software without restriction, including without limitation the
 rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 sell copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */

import UIKit
import AVFoundation
import CoreVideo
import Metal
import Photos

public protocol VideoCaptureDelegate: class {
    func videoCapture(_ capture: VideoCapture, didCaptureVideoTexture texture: MTLTexture?, timestamp: CMTime)
    func videoCapture(_ capture: VideoCapture, didCapturePhotoTexture texture: MTLTexture?, previewImage: UIImage?)
    func getDocumentURL(_ outputFileURL: URL)
}

/**
 Simple interface to the iPhone's camera.
 */
@objc public class VideoCapture: NSObject,//AVCaptureFileOutputRecordingDelegate
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    public var previewLayer: AVCaptureVideoPreviewLayer?
    public weak var delegate: VideoCaptureDelegate?
    public var fps = -1
    public var frame = 0;
    
    let device: MTLDevice
    var textureCache: CVMetalTextureCache?
    let captureSession = AVCaptureSession()
    
    let photoOutput = AVCapturePhotoOutput()
    
    let videoOutput = AVCaptureVideoDataOutput()
    var videoConnection : AVCaptureConnection?
    //音频设备
    var audioMicDevice : AVCaptureDevice?
    var audioOutput = AVCaptureAudioDataOutput()
    var audioConnection : AVCaptureConnection?
    
    //音视频队列
    let queue = DispatchQueue(label: "net.machinethink.camera-queue")
    
    var lastTimestamp = CMTime()
    //视频设备
    var captureDevice: AVCaptureDevice?
    
    //代替编码器的:
    var assetWriter : AVAssetWriter?
    var videoWriterInput : AVAssetWriterInput?
    var audioWriterInput : AVAssetWriterInput?
    var tmpFileURL : NSURL?
    var videoName : NSString? //------------------------------------------6.4有条件的话应该将每一处强制拆包变为if let判断
    
    public var isCapture : Bool = false
    //   public var isPause : Bool = false  -----------------------------------------------------4.25
    public var currentRecordTime : CGFloat = 0.0
    public var discont : Bool = false
    var startTime : CMTime = CMTimeMake(0, 0)
    var timeOffest : CMTime = CMTimeMake(0, 0)
    public var videoPath : NSString? //原来是nsstring
    var samplerate : Float64?
    var channels : UInt32?
    //录制时间
    var timer : Timer?
    var secondCount = 0
    
    public init(device: MTLDevice) {
        self.device = device
        super.init()
    }
    
    public func setUp(sessionPreset: AVCaptureSession.Preset = .medium,
                      completion: @escaping (Bool) -> Void) {
        queue.async {
            let success = self.setUpCamera(sessionPreset: sessionPreset)
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
    
    func setUpCamera(sessionPreset: AVCaptureSession.Preset) -> Bool {
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            print("Error: could not create a texture cache")
            return false
        }
        
        captureSession.beginConfiguration()
        captureSession.sessionPreset = sessionPreset
        
        //指定视频设备
        self.captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
        guard let videoInput = try? AVCaptureDeviceInput(device: self.captureDevice!) else {
            print("Error: could not create AVCaptureDeviceInput--vedio")
            return false
        }
        //指定音频设备
        self.audioMicDevice = AVCaptureDevice.default(for: AVMediaType.audio)
        guard let audioInput = try? AVCaptureDeviceInput(device: self.audioMicDevice!) else {
            print("Error: could not create AVCaptureDeviceInput--audio")
            return false
        }
        
        //添加音频输入设备
        if captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        previewLayer.connection?.videoOrientation = .portrait
        
        self.previewLayer = previewLayer
        
        let settings: [String : Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        
        videoOutput.videoSettings = settings
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        // We want the buffers to be in portrait orientation otherwise they are
        // rotated by 90 degrees. Need to set this _after_ addOutput()!
        //videoOutput.connection(with: AVMediaType.video)?.videoOrientation = .portrait
        videoConnection = videoOutput.connection(with: AVMediaType.video)
        videoConnection?.videoOrientation = AVCaptureVideoOrientation.portrait
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }
        
        //添加音频设备
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
        
        //audioOutput.connection(with: AVMediaType.audio)
        audioConnection = videoOutput.connection(with: AVMediaType.audio)
        captureSession.commitConfiguration()
        return true
    }
    
    //  public func start() {
    //    if !captureSession.isRunning {
    //      captureSession.startRunning()
    //    }
    //  }
    //启动相机捕捉画面
    public func start() {
        startTime = CMTimeMake(0, 0)
        isCapture = false
        //isPause = false
        discont = false
        captureSession.startRunning()
    }
    
    public func startRecording() {
        self.videoName = self.getUploadFile_type(type: "video", fileType: "mp4")
        print("videoName is:",self.videoName!)
        self.videoPath = self.getVideoCachePath().appendingPathComponent(videoName! as String) as NSString
        self.tmpFileURL = NSURL.fileURL(withPath: self.videoPath! as String) as NSURL
        let videoSettings : [String : Any] = [
            AVVideoCodecKey : AVVideoCodecH264,
            AVVideoWidthKey: 240,//------------------------------------------5.10，width>height时，录制的视频是扁的
            AVVideoHeightKey: 320,
            AVVideoCompressionPropertiesKey: [
                AVVideoPixelAspectRatioKey: [
                    AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
                    AVVideoPixelAspectRatioVerticalSpacingKey: 1
                ],
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAverageBitRateKey: 1280000
            ]
        ]
        let audioSettings : [String : Any] = [
            AVFormatIDKey: NSNumber(value: kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 22050
        ]
        do {
            assetWriter = try AVAssetWriter(url: self.tmpFileURL! as URL, fileType: AVFileType.mp4)
            assetWriter?.shouldOptimizeForNetworkUse = true
            videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
            videoWriterInput?.expectsMediaDataInRealTime = true

            if assetWriter!.canAdd(videoWriterInput!){
                assetWriter!.add(videoWriterInput!)
            }
            audioWriterInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = true
            if assetWriter!.canAdd(audioWriterInput!){
                assetWriter!.add(audioWriterInput!)
            }
        } catch _ {

        }
        
    }
    
    public func endRecording() {
        if let assetWriter = self.assetWriter {
            if let videoWriterInput = self.videoWriterInput {
                videoWriterInput.markAsFinished()
            }
            if let audioWriterInput = audioWriterInput {
                audioWriterInput.markAsFinished()
            }
            self.videoWriterInput = nil //---------------------------录制完成后将这三项置为nil,暂时解决了不能多次录制的问题
            self.audioWriterInput = nil
            self.assetWriter = nil
            
            assetWriter.finishWriting(completionHandler: {
                PHPhotoLibrary.shared().performChanges({
                    //创建照片变动请求
                    let assetRequest : PHAssetChangeRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.tmpFileURL! as URL)!
                    //获取APP名为相册的名称
                    //                        let collectionTitleCF = Bundle.main.infoDictionary!["kCFBundleNameKey"]
                    //                        let collectionTitle = collectionTitleCF as! String
                    //创建相册变动请求
                    let collectionRequest : PHAssetCollectionChangeRequest!
                    //取出指定名称的相册
                    let assetCollection : PHAssetCollection? = self.getCurrentPhotoCollectionWithTitle(collectionName:"TakeVedio")
                    //判断相册是否存在
                    if assetCollection != nil { //存在的话直接创建请求
                        collectionRequest = PHAssetCollectionChangeRequest.init(for: assetCollection!)                        }
                    else { //不存在的话创建相册
                        collectionRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "TakeVedio")
                    }
                    //创建一个占位对象
                    let placeHolder : PHObjectPlaceholder! = assetRequest.placeholderForCreatedAsset
                    //将占位对象添加到相册请求中
                    collectionRequest.addAssets([placeHolder] as NSArray)
                    
                }, completionHandler: { (success, error) in
                    if error != nil {
                        print("保存失败！")
                        print("the error is:\(String(describing: error))")
                    } else {
                        print("保存成功！")
                    }
                })
                print("录制完成")
            })
        }
        print("录制完成")
    }
    
    //    public func addAngelLabel() {
    //        //var movieFile = GPUImageMovie.init(url: tmpFileURL! as URL)
    //        //找到视频
    //        let sampleURL = Bundle.main.url(forResource: "video_184235", withExtension: "MP4")
    //        print("sampleURL is:",sampleURL)
    //        let asset = AVAsset.init(url: sampleURL!)
    //        let movieFile = GPUImageMovie.init(asset: asset)
    //        movieFile?.runBenchmark = true
    //        movieFile?.playAtActualSpeed = false
    //
    //        //制作文字水印
    //        //var fileas = AVAsset.init(url: tmpFileURL! as URL)
    //        var containView = UIView.init(frame: CGRect.init(x: 0, y: 0, width: ScreenWidth, height: ScreenHeight))
    //        containView.backgroundColor = UIColor.clear
    //
    //        var angelLabel = UILabel.init(frame: CGRect.init(x: 100, y: 100, width: 100, height: 100))
    //        angelLabel.text = "角度"
    //        angelLabel.font = UIFont.boldSystemFont(ofSize: 30)
    //        angelLabel.textColor = UIColor.red
    //        containView.addSubview(angelLabel)
    //
    //        var UIElement = GPUImageUIElement.init(view: containView)
    //        var blendFilter = GPUImageAlphaBlendFilter.init()
    //        blendFilter.mix = 1.0
    //
    //        //新视频的地址
    //        let pathToMovie = NSHomeDirectory()+"/Documents/temp11223.MP4"
    //        let fileManager = FileManager.default
    //        if fileManager.fileExists(atPath: pathToMovie){
    //            try! fileManager.removeItem(atPath: pathToMovie)
    //        }
    //        let URL = NSURL.fileURL(withPath: pathToMovie)
    //        var movieWriter = GPUImageMovieWriter.init(movieURL: URL, size: CGSize.init(width: 240.0, height: 320.0))
    //
    //        let brightnessFilter = GPUImageBrightnessFilter.init()
    //        brightnessFilter.brightness = 0.0
    //
    //        movieFile?.addTarget(brightnessFilter)
    //        brightnessFilter.addTarget(blendFilter)
    //        UIElement?.addTarget(blendFilter)
    //        blendFilter.addTarget(movieWriter)
    //
    //        movieWriter?.shouldPassthroughAudio = true
    //        movieFile?.audioEncodingTarget = movieWriter
    //        movieFile?.enableSynchronizedEncoding(using: movieWriter)
    //
    //        print("the movieWriter's status is:",movieWriter?.assetWriter.status.rawValue)
    //        movieWriter?.startRecording()
    //        movieFile?.startProcessing()
    //
    //        movieWriter?.completionBlock = {
    //            blendFilter.removeTarget(movieWriter)
    //            movieWriter?.finishRecording()
    //            PHPhotoLibrary.shared().performChanges({
    //                //创建照片变动请求
    //                let assetRequest : PHAssetChangeRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: URL)!
    //                //获取APP名为相册的名称
    //                //                        let collectionTitleCF = Bundle.main.infoDictionary!["kCFBundleNameKey"]
    //                //                        let collectionTitle = collectionTitleCF as! String
    //                //创建相册变动请求
    //                let collectionRequest : PHAssetCollectionChangeRequest!
    //                //取出指定名称的相册
    //                let assetCollection : PHAssetCollection? = self.getCurrentPhotoCollectionWithTitle(collectionName:"VedioWithAngel")
    //                //判断相册是否存在
    //                if assetCollection != nil { //存在的话直接创建请求
    //                    collectionRequest = PHAssetCollectionChangeRequest.init(for: assetCollection!)                        }
    //                else { //不存在的话创建相册
    //                    collectionRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "VedioWithAngel")
    //                }
    //                //创建一个占位对象
    //                let placeHolder : PHObjectPlaceholder! = assetRequest.placeholderForCreatedAsset
    //                //将占位对象添加到相册请求中
    //                collectionRequest.addAssets([placeHolder] as NSArray)
    //
    //            }, completionHandler: { (success, error) in
    //                if error != nil {
    //                    print("角度保存失败！")
    //                } else {
    //                    print("角度保存成功！")
    //                }
    //            })
    //    }//end of completionBlock
    //}
    
    //  public func stop() {
    //    if captureSession.isRunning {
    //      captureSession.stopRunning()
    //    }
    //  }
    
    //取出指定名称的相册集合
    func getCurrentPhotoCollectionWithTitle(collectionName:String) ->PHAssetCollection? {
        //创建搜索集合
        let result : PHFetchResult = PHAssetCollection.fetchAssetCollections(with:.album , subtype: .albumRegular, options: nil)
        //遍历所有集合取出特定相册
        for index in 0..<result.count {
            if (result.object(at: index).localizedTitle! == collectionName) {
                return result.object(at: index)
            }
        }
        return nil
    }
    //}
    
    
    //获取视频的第一帧图片
    //    func movieToImageHandler(handler: @escaping (_ movieImage : UIImage) -> ()) {
    //        //创建URL
    //        let url = NSURL.fileURL(withPath: videoPath! as String)
    //        //根据URL创建AVURLAsset
    //        let asset = AVURLAsset.init(url: url, options: nil)
    //        //生成视频截图
    //        let generator = AVAssetImageGenerator.init(asset: asset)
    //        generator.appliesPreferredTrackTransform = true
    //        let thumbTime = CMTimeMakeWithSeconds(0, 60)
    //        let value = NSValue.init(time: thumbTime)
    //        generator.apertureMode = AVAssetImageGeneratorApertureMode.encodedPixels
    //        generator.generateCGImagesAsynchronously(forTimes: [value]) { (requestedTime, im, actualTime, result, error) in
    //            if (result == AVAssetImageGeneratorResult.succeeded) {
    //                let thumbImage = UIImage.init(cgImage: im!)
    //                DispatchQueue.main.async {
    //                    handler(thumbImage)
    //                }
    //            }
    //        }
    //    }
    
    //将MOV文件转化为MP4文件
    func changeMovToMp4(mediaURL : NSURL, handler:@escaping (_ movieImage : UIImage) -> ()) {
        let video = AVAsset.init(url: mediaURL as URL)
        let exportSession = AVAssetExportSession.init(asset: video, presetName: AVAssetExportPreset1280x720)
        exportSession?.shouldOptimizeForNetworkUse = true
        exportSession?.outputFileType = AVFileType.mp4
        let basePath : NSString = getVideoCachePath()
        self.videoPath = basePath.appendingPathComponent(getUploadFile_type(type: "video", fileType: "mp4") as String) as NSString
        print("videoPath:%@",videoPath!)
        exportSession?.outputURL = NSURL.fileURL(withPath: self.videoPath! as String)
        exportSession?.exportAsynchronously(completionHandler: {
            //self.movieToImageHandler(handler: handler)
        })
    }
    
    //获得视频存放地址
    func getVideoCachePath()->NSString {
        let temporary = NSTemporaryDirectory() as NSString
        let videoCache = temporary.appendingPathComponent("video") as NSString
        print("videoCache is:",videoCache)
        var isDir : ObjCBool = ObjCBool(false);
        let fileManager = FileManager.default
        let existed : Bool = fileManager.fileExists(atPath: videoCache as String, isDirectory: &isDir)
        if (!(existed == true && isDir.boolValue == true)) {
            do {
                try fileManager.createDirectory(atPath: videoCache as String, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("timeInterval error!")
            }
        }
        return videoCache
    }
    //文件存放地址
    public func getRecordAngleFilePath()->NSString {
        let documentPaths = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.allDomainsMask, true)
        let documentPath = documentPaths[0] as NSString
        //let documentPath = NSTemporaryDirectory() as NSString
        let txtName = self.getUploadFile_type(type: "video", fileType: "json")
        let angleFilePath = documentPath.appendingPathComponent("\(txtName)") as NSString
        print("the angleFilePath is:", angleFilePath)
//        var isDir : ObjCBool = ObjCBool(false);
//        let fileManager = FileManager.default
//        let existed : Bool = fileManager.fileExists(atPath: angleFilePath as String, isDirectory: &isDir)
//        if (!(existed == true && isDir.boolValue == true)) {
//            do {
//                try fileManager.createDirectory(atPath: angleFilePath as String, withIntermediateDirectories: true, attributes: nil)
//            } catch {
//                print("creatAngleFilePath error!")
//            }
//        }
        return angleFilePath
    }
    
    func getUploadFile_type(type : NSString, fileType : NSString)->NSString {
        let now = NSDate()
        let timeInterval : TimeInterval
        timeInterval = now.timeIntervalSince1970
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        
        let nowDate : NSDate =  NSDate.init(timeIntervalSince1970: timeInterval)
        let timeStr : NSString = formatter.string(from: nowDate as Date) as NSString
        let fileName : NSString = NSString.init(format: "%@_%@.%@", type, timeStr,fileType)
        return fileName
    }
    
    //    func setAudioFormat(fmt : CMFormatDescription) {
    //        let asbd : UnsafePointer<AudioStreamBasicDescription>
    //        asbd = (CMAudioFormatDescriptionGetStreamBasicDescription(fmt))!
    //        self.samplerate = asbd.pointee.mSampleRate
    //        self.channels = asbd.pointee.mChannelsPerFrame
    //    }
    //
    //调整媒体数据的时间
    //    func adjustTime(sample : CMSampleBuffer, offset : CMTime) ->CMSampleBuffer {
    //        let count : CMItemCount!
    //        CMSampleBufferGetSampleTimingInfo(sample, 0, count)
    //    }
    
    /* Captures a single frame of the camera input. */
    public func capturePhoto() {
        let settings = AVCapturePhotoSettings(format: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
            ])
        
        settings.previewPhotoFormat = [
            kCVPixelBufferPixelFormatTypeKey as String: settings.__availablePreviewPhotoPixelFormatTypes[0],
            kCVPixelBufferWidthKey as String: 480,
            kCVPixelBufferHeightKey as String: 360,
        ]
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func convertToMTLTexture(sampleBuffer: CMSampleBuffer?) -> MTLTexture? {
        if let textureCache = textureCache, //纹理缓存
            let sampleBuffer = sampleBuffer, //视频的每一帧转化为图像
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            
            var texture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache,
                                                      imageBuffer, nil, .bgra8Unorm, width, height, 0, &texture)
            
            if let texture = texture {
                return CVMetalTextureGetTexture(texture)
            }
        }
        return nil
    }
    
    func convertToUIImage(sampleBuffer: CMSampleBuffer?) -> UIImage? {
        if let sampleBuffer = sampleBuffer,
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let ciContext = CIContext(options: nil)
            if let cgImage = ciContext.createCGImage(ciImage, from: rect) {
                return UIImage(cgImage: cgImage)
            }
        }
        return nil
    }
    
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { //下划线表示具有默认的外部参数名，如果不想使用默认的外部参数名可以使用下划线进行忽略
        // Because lowering the capture device's FPS looks ugly in the preview,
        // we capture at full speed but only call the delegate at its desired
        // framerate. If `fps` is -1, we run at the full framerate.
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        //frame += 1
        //print("the current frame is:",frame)
        let deltaTime = timestamp - lastTimestamp
        if fps == -1 || deltaTime >= CMTimeMake(1, Int32(fps)) {
            lastTimestamp = timestamp
            
            let texture = convertToMTLTexture(sampleBuffer: sampleBuffer)
            delegate?.videoCapture(self, didCaptureVideoTexture: texture, timestamp: timestamp)
        }
        if let assetWriter = assetWriter {
            if assetWriter.status != .writing && assetWriter.status != .unknown {
                return
            }
        }
        if let assetWriter = assetWriter, assetWriter.status == AVAssetWriterStatus.unknown {
            let startTime : CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: startTime)
        }
        if connection == self.videoConnection {
            queue.async(execute: {
                if let videoWriterInput = self.videoWriterInput,videoWriterInput.isReadyForMoreMediaData {
                    videoWriterInput.append(sampleBuffer)
                }
            })
        }
        else if connection == self.audioConnection {
            queue.async(execute: {
                if let audioWriterInput = self.audioWriterInput,audioWriterInput.isReadyForMoreMediaData {
                    audioWriterInput.append(sampleBuffer)
                }
            })
        }
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        //print("dropped frame")
    }
    
}

extension VideoCapture: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ captureOutput: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?,
                            previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?,
                            resolvedSettings: AVCaptureResolvedPhotoSettings,
                            bracketdSettings: AVCaptureBracketedStillImageSettings?,
                            error: Error?) {
        
        var imageTexture: MTLTexture?
        var previewImage: UIImage?
        if error == nil {
            imageTexture = convertToMTLTexture(sampleBuffer: photoSampleBuffer)
            previewImage = convertToUIImage(sampleBuffer: previewPhotoSampleBuffer)
        }
        delegate?.videoCapture(self, didCapturePhotoTexture: imageTexture, previewImage: previewImage)
    }
}

