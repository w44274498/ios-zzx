import UIKit
import Metal
import MetalPerformanceShaders
import AVFoundation
import CoreMedia
import CoreLocation
import CoreMotion
import Forge
import Photos
import SnapKit

let ScreenWidth : CGFloat = UIScreen.main.bounds.size.width
let ScreenHeight : CGFloat = UIScreen.main.bounds.size.height
let MaxBuffersInFlight = 3   // use triple buffering

// The labels for the 20 classes.
let labels = [
    "aeroplane", "bicycle", "bird", "boat", "bottle", "bus", "car", "cat",
    "chair", "cow", "diningtable", "dog", "horse", "motorbike", "person",
    "pottedplant", "sheep", "sofa", "train", "tvmonitor"
]

class CameraViewController: UIViewController, CLLocationManagerDelegate {
    
    @IBOutlet weak var videoPreview: UIView!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var debugImageView: UIImageView!
    
    var videoCapture: VideoCapture!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var runner: Runner!
    var network: YOLO!
    
    var startupGroup = DispatchGroup()
    
    var boundingBoxes = [BoundingBox]()
    var colors: [UIColor] = []
    let fpsCounter = FPSCounter()
    
    var tapOne = UITapGestureRecognizer()
    var predictionResult = [YOLO.Prediction]()
    //量角器层
    var myprotractorView : myProtractorView!
    //输出测试
    var textLabel : UILabel!
    var textValue : String?
    //sliderBar
    var slider = UISlider()
    //拍照按钮
    var startRecordBtn : UIButton!
    //本地视频按钮
    var photoLibraryBtn : UIButton!
    //保存按钮
    var saveVedioBtn : UIButton!
    //视频地址
    var documentURL : URL?
    //测试手机朝向的变量
    var startHeadingLabel : UILabel!
    var newHeadingLabel : UILabel!
    var differHeadingLabel : UILabel!
    var videoChangeLabel : UILabel!
    
    var startHeadingAngle : Double?
    var newHeadingAngle : Double?
    var differHeadingAngle : Double = 0
    var videoChangeAngle : Double?
    //视频帧数的变量
    var startRecordFrame : Int?
    var recordFileFrame : Int?
    var isRecordBtnSelected : Bool?
    
    //txt文件
    var angleMsg : NSMutableArray?
    var angleDocAddress : NSString?
    
    //传感器相关变量
    //    var w : Double?
    //    var w1 : Double?
    //    var rollingX : Double?
    //    var rollingY : Double?
    //    var rollingZ : Double?
    var r1: Double?
    var r : Double?
    var kesai1 : Double?
    var kesai: Double?
    
    var motionManager : CMMotionManager!
    var locationManager : CLLocationManager!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        //注册通知
        NotificationCenter.default.addObserver(self, selector: #selector(showTextLabel), name: NSNotification.Name(rawValue: "sendAngleFromProtractorLayer"), object: nil)
        
//        NotificationCenter.default.addObserver(self, selector: #selector(writeAngleToFile), name: NSNotification.Name(rawValue: "sendIsStartRecordBtnSelected"), object: nil)
        
        timeLabel.text = ""
        
        device = MTLCreateSystemDefaultDevice()
        if device == nil {
            print("Error: this device does not support Metal")
            return
        }
        motionManager = CMMotionManager()
        
        print("屏幕的宽为：",self.view.size.width);
        print("屏幕的长为：",self.view.size.height);
        
        
        //启动加速传感器
        motionManager.accelerometerUpdateInterval = 0.25
        if (motionManager.isAccelerometerAvailable) {
            let queue = OperationQueue.current
            motionManager.startAccelerometerUpdates(to: queue!, withHandler:
                { (accelerometerData, error) in
                    guard error == nil else {
                        print ("获取加速度传感器错误")
                        return
                    }
                    self.calculateAR()
            })
        }
        locationManager = CLLocationManager.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.headingFilter = 2
        locationManager.startUpdatingHeading()
        
        commandQueue = device.makeCommandQueue()
        
        // Set up the bounding boxes.
        for _ in 0..<YOLO.maxBoundingBoxes {
            boundingBoxes.append(BoundingBox())
        }
        
        // Make colors for the bounding boxes. There is one color for each class,
        // 20 classes in total.
        for r: CGFloat in [0.2, 0.4, 0.6, 0.8, 1.0] {
            for g: CGFloat in [0.3, 0.7] {
                for b: CGFloat in [0.4, 0.8] {
                    let color = UIColor(red: r, green: g, blue: b, alpha: 1)
                    colors.append(color)
                }
            }
        }
        
        videoCapture = VideoCapture(device: device)
        videoCapture.delegate = self
        
        // Initialize the camera.
        startupGroup.enter()
        videoCapture.setUp(sessionPreset: .vga640x480) { success in
            // Add the video preview into the UI.
            if let previewLayer = self.videoCapture.previewLayer {
                self.videoPreview.layer.addSublayer(previewLayer)
                self.resizePreviewLayer()
            }
            
            self.startupGroup.leave()
        }
        
        
        //添加按钮
        self.setupButton()
        
        // Initialize the neural network.
        startupGroup.enter()
        createNeuralNetwork {
            print("network build successfully!")
            self.startupGroup.leave()
        }
        
        startupGroup.notify(queue: .main) {
            // Add the bounding box layers to the UI, on top of the video preview.
            for box in self.boundingBoxes {
                box.addToLayer(self.videoPreview.layer)
            }
            
            // Once the NN is set up, we can start capturing live video.
            self.fpsCounter.start()
            self.videoCapture.start()
        }
        
        /*
         添加单击手势，进行焦距的缩放
         */
        tapOne = UITapGestureRecognizer(target: self, action:#selector(tapToChangeZoom(_:)))
        self.view.addGestureRecognizer(tapOne);
        
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        print(#function)
    }
    
    //    override func viewWillAppear(_ animated: Bool) {
    //        self.fpsCounter.start()
    //        self.videoCapture.start()
    //    }
    deinit {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: "sendAngleFromProtractorLayer"), object: nil)
    }
    
    //MARK: - UI stuff
    //创建按钮
    func setupButton() {
        //初始化slider
        slider.frame = CGRect.init(x: 30, y: 50, width: 200, height: 20)
        slider.minimumValue = 1.0
        slider.maximumValue = 3.0
        slider.value = 1.5
        slider.thumbTintColor = UIColor.red
        self.view.addSubview(slider)
        slider.addTarget(self, action: #selector(changeZoomFactor(slider:)), for: UIControlEvents.valueChanged)
        
        //初始化myprotractorView
        myprotractorView = myProtractorView.init(frame: CGRect.init(x: 0, y: 527.8, width: ScreenWidth, height: 179.2)) //812-60-40-10-179.2
        self.view.addSubview(myprotractorView)
        
        //
        textLabel = UILabel.init(frame: CGRect.init(x: 0, y: 0, width: 200, height: 20))
        textLabel.backgroundColor = UIColor.yellow
        self.view.addSubview(textLabel)
        textLabel.snp.makeConstraints { (make) in
            make.top.equalTo(slider.snp.bottom).offset(10)
            make.left.equalTo(slider.snp.left)
        }
        
        //测试角度的label
        startHeadingLabel = UILabel.init(frame: CGRect.init(x: 0, y: 0, width: 200, height: 20))
        startHeadingLabel.backgroundColor = UIColor.yellow
        self.view.addSubview(startHeadingLabel)
        startHeadingLabel.snp.makeConstraints { (make) in
            make.top.equalTo(textLabel.snp.bottom).offset(20)
            make.left.equalTo(textLabel.snp.left)
        }
        
        newHeadingLabel = UILabel.init(frame: CGRect.init(x: 0, y: 0, width: 200, height: 20))
        newHeadingLabel.backgroundColor = UIColor.yellow
        self.view.addSubview(newHeadingLabel)
        newHeadingLabel.snp.makeConstraints { (make) in
            make.top.equalTo(startHeadingLabel.snp.bottom).offset(20)
            make.left.equalTo(startHeadingLabel.snp.left)
        }
        
        differHeadingLabel = UILabel.init(frame: CGRect.init(x: 0, y: 0, width: 200, height: 20))
        differHeadingLabel.backgroundColor = UIColor.yellow
        self.view.addSubview(differHeadingLabel)
        differHeadingLabel.snp.makeConstraints { (make) in
            make.top.equalTo(newHeadingLabel.snp.bottom).offset(20)
            make.left.equalTo(startHeadingLabel.snp.left)
        }
        
        videoChangeLabel = UILabel.init(frame: CGRect.init(x: 0, y: 0, width: 200, height: 20))
        videoChangeLabel.backgroundColor = UIColor.yellow
        self.view.addSubview(videoChangeLabel)
        videoChangeLabel.snp.makeConstraints { (make) in
            make.top.equalTo(differHeadingLabel.snp.bottom).offset(20)
            make.left.equalTo(startHeadingLabel.snp.left)
        }
        
        //拍照按钮
        startRecordBtn = UIButton.init()
        startRecordBtn.setImage(UIImage.init(named: "startRecordPic"), for:.normal)
        startRecordBtn.addTarget(self, action: #selector(clickOnStartRecordBtn(_:)), for: .touchUpInside)
        self.view.addSubview(startRecordBtn)
        
        startRecordBtn.snp.makeConstraints { (make) in
            make.width.height.equalTo(60)
            make.bottom.equalTo(self.view.snp.bottom).offset(-40)
            make.centerX.equalTo(self.view)
        }
        
        //本地视频按钮
        photoLibraryBtn = UIButton.init()
        photoLibraryBtn.setImage(UIImage.init(named: "photoLibrary"), for: .normal)
        self.view.addSubview(photoLibraryBtn)
        
        photoLibraryBtn.snp.makeConstraints { (make) in
            make.width.equalTo(startRecordBtn)
            make.height.equalTo(startRecordBtn)
            make.bottom.equalTo(startRecordBtn)
            make.left.equalTo(startRecordBtn.snp.right).offset(60)
        }
        
        //保存按钮
        saveVedioBtn = UIButton.init();
        saveVedioBtn.setTitle("save", for: .normal)
        saveVedioBtn.backgroundColor = UIColor.yellow
        saveVedioBtn.setTitleColor(UIColor.red, for: .normal)
        self.view.addSubview(saveVedioBtn)
        saveVedioBtn.snp.makeConstraints { (make) in
            make.top.equalTo(self.view).offset(50)
            make.right.equalTo(self.view).offset(-20)
            make.size.equalTo(CGSize.init(width: 80, height: 40))
        }
        saveVedioBtn.addTarget(self, action: #selector(clickOnSaveVedioBtn(_:)), for: .touchUpInside)
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        resizePreviewLayer()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent //手机顶部显示时间，网络的状态栏，lightContent表示白色
    }
    
    func resizePreviewLayer() {
        videoCapture.previewLayer?.frame = videoPreview.bounds
    }
    
    // MARK: - Neural network
    
    func createNeuralNetwork(completion: @escaping () -> Void) {
        // Make sure the current device supports MetalPerformanceShaders.
        guard MPSSupportsMTLDevice(device) else { //在条件不符合时执行else中的代码
            print("Error: this device does not support Metal Performance Shaders")
            return
        }
        
        runner = Runner(commandQueue: commandQueue, inflightBuffers: MaxBuffersInFlight)
        
        // Because it may take a few seconds to load the network's parameters,
        // perform the construction of the neural network in the background.
        DispatchQueue.global().async {
            
            timeIt("Setting up neural network") {
                self.network = YOLO(device: self.device, inflightBuffers: MaxBuffersInFlight)
            }
            
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    func predict(texture: MTLTexture) {
        // Since we want to run in "realtime", every call to predict() results in
        // a UI update on the main thread. It would be a waste to make the neural
        // network do work and then immediately throw those results away, so the
        // network should not be called more often than the UI thread can handle.
        // It is up to VideoCapture to throttle how often the neural network runs.
        
        runner.predict(network: network, texture: texture, queue: .main) { result in
            self.show(predictions: result.predictions)
            self.predictionResult = result.predictions
            
            if let texture = result.debugTexture {
                self.debugImageView.image = UIImage.image(texture: texture)
            }
            
            self.fpsCounter.frameCompleted()
            self.timeLabel.text = String(format: "%.1f FPS (latency: %.5f sec)", self.fpsCounter.fps, result.latency)
            self.fpsCounter.startFrameCounter()
            if let startRecordFrame = self.startRecordFrame {
                self.recordFileFrame = self.fpsCounter.videoFrames - startRecordFrame
                self.videoChangeAngle = (self.textValue as! NSString).doubleValue + self.differHeadingAngle
                self.videoChangeLabel.text = "录制角度变化为:\(self.videoChangeAngle!)"
                //写入txt格式的文件
                let angle = (self.videoChangeLabel.text as! NSString).doubleValue
                let frameToString = String.init(format:"frame:%d,angle:%.2f",self.recordFileFrame!,self.videoChangeAngle!)
//                self.angleMsg?.append(NSData(data:frameToString.data(using: String.Encoding.utf8, allowLossyConversion: true)!) as Data)
                self.angleMsg?.add(frameToString)
                
                //print("the recordFileFrame is:", self.recordFileFrame)
                //let frameToString = String(self.recordFileFrame!, radix:10)
                //var information = ("current frame is:" as NSString).appending(frameToString)
                //let information = "hello"
                //let path = self.videoCapture.getRecordAngleFilePath()
                //let tempURL = NSURL.fileURL(withPath: path as String) as URL
                
//                do{
//                    //try frameToString.write(to: tempURL, atomically: true, encoding: String.Encoding.utf8)
//                    //try information.write(to: tempURL, atomically: true, encoding: String.Encoding.utf8)
//                    try information.write(to: tempURL, atomically: true, encoding: String.Encoding.utf8)
//                }catch {
//                    print(error)
//                  }
            }
        }
    }
    
    private func show(predictions: [YOLO.Prediction]) {
        for i in 0..<boundingBoxes.count { //开区间
            if i < predictions.count && predictions[i].classIndex == 14{
                let prediction = predictions[i]
                
                // The predicted bounding box is in the coordinate space of the input
                // image, which is a square image of 416x416 pixels. We want to show it
                // on the video preview, which is as wide as the screen and has a 4:3
                // aspect ratio. The video preview also may be letterboxed at the top
                // and bottom.
                let width = view.bounds.width
                let height = width * 4 / 3
                let scaleX = width / CGFloat(YOLO.inputWidth)
                let scaleY = height / CGFloat(YOLO.inputHeight)
                let top = (view.bounds.height - height) / 2
                
                // Translate and scale the rectangle to our own coordinate system.
                var rect = prediction.rect
                rect.origin.x *= scaleX
                rect.origin.y *= scaleY
                rect.origin.y += top
                rect.size.width *= scaleX
                rect.size.height *= scaleY
                
                // Show the bounding box.
                let label = String(format: "%@ %.1f", labels[prediction.classIndex], prediction.score * 100)
                let color = colors[prediction.classIndex]
                boundingBoxes[i].show(frame: rect, label: label, color: color)
                
            } else {
                boundingBoxes[i].hide()
            }
        }
    }
    //ignore
    private func calculateAR() {
        //let w1 = locationManager.heading?.trueHeading;
        //let w1 = 0.0
        let accelerometerData : CMAccelerometerData = (motionManager.accelerometerData)!
        let rollingX = accelerometerData.acceleration.x
        let rollingY = accelerometerData.acceleration.y
        let rollingZ = accelerometerData.acceleration.z
        
        startupGroup.enter()
        if (rollingY == 0) {
            if (rollingX > 0.0) {
                r1 = 0.0;
            }
            else {
                r1 = 90.0;
            }
        }
        else
        {
            r1 = atan(rollingX / rollingY) * 180 / Double.pi;
            if (rollingY > 0.0) {
                r1 = r1! + 180.0;
            }
            
        }
        r = r1!
        if (-45 < r! && r! < 45) {
            kesai1 = atan(rollingZ / rollingY);
        }
        if (135 < r! && r! < 225) {
            kesai1  = -atan(rollingZ / rollingY);
        }
        if (45 <= r! && r! <= 135) {
            kesai1 = atan(rollingZ / rollingX);
        }
        if (-90 <= r! && r! <= -45) {
            kesai1 = -atan(rollingZ / rollingX);
        }
        if (225 <= r! && r! <= 270) {
            kesai1 = -atan(rollingZ / rollingX);
        }
        kesai1 = kesai1! / Double.pi * 180;
        kesai = kesai1;
        while (kesai! > 90) {
            kesai = kesai! - 180;
        }
        while (kesai! < -90) {
            kesai = kesai! + 180;
        }
        
        if(r!.isNaN){
            r = 0;
        }
        if(kesai!.isNaN){
            kesai = 0;
        }
        self.startupGroup.leave()
        
        startupGroup.notify(queue: .main){
            let protractor_transform : CATransform3D = CATransform3DMakeRotation(CGFloat((self.kesai! * (-1.1442) + 63.879) * Double.pi / 180), 1, 0, 0)
            self.myprotractorView.myProtractorLayer?.transform = self.CATransform3DPerspect(t: protractor_transform, center: CGPoint(x:0,y:0), disZ: 200)
        }
    }
    
    // MARK: - 量角器姿态控制相关函数
    private func CATransform3DMakePerspective(center : CGPoint, disZ : Float) -> CATransform3D {
        let transToCenter : CATransform3D = CATransform3DMakeTranslation(-center.x, -center.y, 0)
        let transBack : CATransform3D = CATransform3DMakeTranslation(center.x, center.y, 0)
        var scale : CATransform3D! = CATransform3DIdentity
        scale.m34 = CGFloat(-1.0/disZ)
        return (CATransform3DConcat(transToCenter, scale), transBack)
    }
    
    private func CATransform3DPerspect(t : CATransform3D, center : CGPoint, disZ : Float) -> CATransform3D {
        return CATransform3DConcat(t, self.CATransform3DMakePerspective(center: center, disZ: disZ))
    }
    
    //手势点击识别框相应函数
    @objc func tapToChangeZoom (_ recognizer:UITapGestureRecognizer) {
        
        let point = recognizer.location(in: self.view)
        let x = point.x
        let y = point.y
        print("点击的点的位置为：\(x),\(y)")
        print("boundingBox的数量为：",self.predictionResult.count)
        for box in self.predictionResult {
            var boxFrame = box.rect
            let width = view.bounds.width
            let height = width * 4 / 3
            let scaleX = width / CGFloat(YOLO.inputWidth)
            let scaleY = height / CGFloat(YOLO.inputHeight)
            let top = (view.bounds.height - height) / 2
            
            boxFrame.origin.x *= scaleX
            boxFrame.origin.y *= scaleY
            boxFrame.origin.y += top
            boxFrame.size.width *= scaleX
            boxFrame.size.height *= scaleY
            
            let boxMinX = boxFrame.origin.x
            let boxMinY = boxFrame.origin.y
            let boxMaxX = boxFrame.origin.x + boxFrame.size.width
            let boxMaxY = boxFrame.origin.y + boxFrame.size.height
            
            //print("classIndex为：",boundingBoxes[i].classIndex)
            print("位置为：（\(boxMinX),\(boxMinY),\(boxMaxX),\(boxMaxY)）")
            
            //let range = box.getLabel().range(of: "person")
            if (boxMinX < x) && (x < boxMaxX) && (boxMinY < y) && (y < boxMaxY) && (box.classIndex == 14){
                textLabel.text = "识别到了人";
                do{
                    try self.videoCapture.captureDevice?.lockForConfiguration()
                } catch {
                    print("Error: lockForConfiguration.")
                }
                //self.videoCapture.captureDevice?.videoZoomFactor = 1.5
                let boxHeight = boxFrame.height
                let percent = boxHeight/ScreenHeight
                let zoom = 0.5/percent
                if (zoom > 1) {
                    self.videoCapture.captureDevice?.videoZoomFactor = zoom
                    self.slider.value = Float(zoom)
                } else {
                    textLabel.text = "已经符合大小"
                }
                self.videoCapture.captureDevice?.unlockForConfiguration()
            }
        }
    }
    // MARK: - notificationCenter的函数
    //textLabel显示量角器角度
    @objc func showTextLabel(notification : NSNotification) {
        textValue = notification.object as! String
        //print("the textValue is:",textValue)
        self.textLabel.text = String.init(format: "现在的角度是：%@", textValue!)
    }
    //将角度写入文件
//    @objc func writeAngleToFile(notification : Notification) {
//        if notification.object != nil {
//            self.isRecordBtnSelected = notification.object as! Bool
//            if isRecordBtnSelected! {
//                let frameToString = String(self.recordFileFrame!, radix:10)
//                var information = ("current frame is:" as NSString).appending(frameToString)
//                let path = self.videoCapture.getRecordAngleFilePath()
//                print("the frame wrote to file is:",frameToString)
//                print("the path of file is:",path)
//                //information.write(toFile: path, atomically: true, encoding: NSUTF8StringEncoding)
//            }
//        }
//    }
    
    
    //相应slider改变的函数
    @objc func changeZoomFactor(slider:UISlider) {
        let value = slider.value
        print("slider的值为：",slider.value)
        do{
            try self.videoCapture.captureDevice?.lockForConfiguration()
        } catch {
            print("Error: lockForConfiguration.")
        }
        self.videoCapture.captureDevice?.videoZoomFactor = CGFloat(value)
        self.videoCapture.captureDevice?.unlockForConfiguration()
    }
    
    //点击录像按钮相应函数
    @objc func clickOnStartRecordBtn(_ sender:UIButton) {
        startRecordBtn.isSelected = !startRecordBtn.isSelected
       // NotificationCenter.default.post(name: NSNotification.Name(rawValue: "sendIsStartRecordBtnSelected"), object: self.startRecordBtn.isSelected)
        if (startRecordBtn.isSelected) {
            //self.videoCapture.startCapture() -----------------------------------------------------4.25
            self.videoCapture.startRecording()
            startRecordBtn.setImage(UIImage.init(named: "finishRecordPic"), for: .normal)
            //角度相关
            self.startHeadingAngle = locationManager.heading?.trueHeading
            self.startHeadingLabel.text = "角度为：\(self.startHeadingAngle!)"
            self.startRecordFrame = self.fpsCounter.videoFrames
            print("the startRecordFrame is:",self.startRecordFrame!)
            
            //保存txt文件
            self.angleDocAddress = self.videoCapture.getRecordAngleFilePath()
            self.angleMsg = NSMutableArray()
        
        }else {
            self.videoCapture.endRecording()
//            self.angleMsg?.write(toFile: self.angleDocAddress as! String, atomically: true)
//            print("finish writing to angle txt\n")
//            let text = try! String.init(contentsOfFile: self.angleDocAddress as! String, encoding: String.Encoding.utf8)
//            print("the text is:",text)
            if(!JSONSerialization.isValidJSONObject(self.angleMsg)){
                print("is not valid json object")
                return
            }
            let data = try? JSONSerialization.data(withJSONObject: self.angleMsg, options: JSONSerialization.WritingOptions.prettyPrinted)
            //let string = String(data: data!, encoding: String.Encoding.utf8)
            let file_url = NSURL.fileURL(withPath: self.angleDocAddress as! String)
            do{
                try data?.write(to: file_url)
            }catch {
                print("write fo file error:\(error)")
            }
            print("finish writing to angle txt\n")
            let text = try! String.init(contentsOfFile: self.angleDocAddress as! String, encoding: String.Encoding.utf8)
            print("the json string is:",text)
            self.startRecordFrame = nil
            //self.videoCapture.finishRecord() -----------------------------------------------------4.25
            //self.videoCapture.stop()
            //            DispatchQueue.main.async {
            //            if(self.videoCapture.recordEncoder == nil){
            //                print( "recordEncoder is nil")
            //            }
            //                self.videoCapture.recordEncoder?.finish(completionHandler: {
            //                    self.videoCapture.isCapture = false
            //                    self.videoCapture.recordEncoder = nil
            //                    self.videoCapture.startTime = CMTimeMake(0, 0)
            //                    self.videoCapture.currentRecordTime = 0
            //
            ////                    let saveAlertController = UIAlertController.init(title: "提示", message: "是否保存视频", preferredStyle: .alert)
            ////                    let cancelAction = UIAlertAction.init(title: "取消", style: .cancel, handler: nil)
            ////                    let okAction = UIAlertAction.init(title: "确定", style: .default, handler: { (action) in
//                                    PHPhotoLibrary.shared().performChanges({
//                                        //创建照片变动请求
//                                        let assetRequest : PHAssetChangeRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.documentURL!)!
//                                        //获取APP名为相册的名称
//                                        //                        let collectionTitleCF = Bundle.main.infoDictionary!["kCFBundleNameKey"]
//                                        //                        let collectionTitle = collectionTitleCF as! String
//                                        //创建相册变动请求
//                                        let collectionRequest : PHAssetCollectionChangeRequest!
//                                        //取出指定名称的相册
//                                        let assetCollection : PHAssetCollection? = self.getCurrentPhotoCollectionWithTitle(collectionName: "TakeVedio")
//                                        //判断相册是否存在
//                                        if assetCollection != nil { //存在的话直接创建请求
//                                            collectionRequest = PHAssetCollectionChangeRequest.init(for: assetCollection!)
//
//                                        }
//                                        else { //不存在的话创建相册
//                                            collectionRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "TakeVedio")
//                                        }
//                                        //创建一个占位对象
//                                        let placeHolder : PHObjectPlaceholder! = assetRequest.placeholderForCreatedAsset
//                                        //将占位对象添加到相册请求中
//                                        collectionRequest.addAssets([placeHolder!] as NSArray)
//                                    }, completionHandler: { (success, error) in
//                                        if error != nil {
//                                            print("保存失败！")
//                                        } else {
//                                            print("保存成功！")
//                                        }
//                                    }
//                                    )
//                                //})
            ////                    saveAlertController.addAction(cancelAction)
            ////                    saveAlertController.addAction(okAction)
            ////                    self.present(saveAlertController, animated: false, completion: nil)
            //                })
            ////            }
            startRecordBtn.setImage(UIImage.init(named: "startRecordPic"), for: .normal)
        }
    }
    
    @objc func clickOnSaveVedioBtn(_ sender:UIButton){
        print("点击了保存按钮")
//        let dict : Dictionary<String,Int> = ["frame1":45, "frame2":45]
//        let isYes : Bool = JSONSerialization.isValidJSONObject(dict)
//        if isYes {
//            let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: JSONSerialization.WritingOptions(rawValue: 0))
//            let documentPaths = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.allDomainsMask, true)
//            let documentPath = documentPaths[0] as NSString
//            //let json_path = documentPath.appending("jsonFile.json")
//            //let json_path = NSHomeDirectory() + "/Documents/jsonFile.json"
//            if let json_path = Bundle.main.path(forResource: "test for YOLO", ofType: "txt") {
//                let fileManager = FileManager.default
//                fileManager.createFile(atPath: json_path, contents: nil, attributes: nil)
//                let handler = FileHandle.init(forWritingAtPath: json_path)
//                handler?.write(jsonData!)
//            }
//
//        }
        
        let documentPaths = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.allDomainsMask, true)
        let documentPath = documentPaths[0] as NSString
        let file_path = documentPath.appendingPathComponent("test.txt")
        print("the file_path is:",file_path)
        let msg = NSMutableData()
        
        let frameToString = String.init(format: "%.2f", self.startHeadingAngle!)
        print("the startFrame is:", frameToString)
        msg.append(NSData(data:"hello".data(using: String.Encoding.utf8, allowLossyConversion: true)!) as Data)
        //msg.write(toFile: file_path, atomically: true)
        
        msg.append(NSData(data:frameToString.data(using: String.Encoding.utf8, allowLossyConversion: true)!) as Data)
        msg.write(toFile: file_path, atomically: true)
        let text = try! String.init(contentsOfFile: file_path, encoding: String.Encoding.utf8)
        print("the text is:",text)
    }
    
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
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        self.newHeadingLabel.text = "方向为:\(newHeading.trueHeading)"
        self.newHeadingAngle = newHeading.trueHeading
        if let textValue = self.textValue{
            if let startHeadingAngle = self.startHeadingAngle {
                self.differHeadingAngle = self.newHeadingAngle! - startHeadingAngle
                if(self.differHeadingAngle < -180.0) {
                    self.differHeadingAngle = (self.newHeadingAngle! - startHeadingAngle + 360).truncatingRemainder(dividingBy: 360.0)
                }
                self.differHeadingLabel.text = "转过差值为:\(differHeadingAngle)"
//                self.videoChangeAngle = (textValue as NSString).doubleValue + self.differHeadingAngle!
//                self.videoChangeLabel.text = "录制角度变化为:\(self.videoChangeAngle)"
            }
        }
    }
}



extension CameraViewController: VideoCaptureDelegate {
    func videoCapture(_ capture: VideoCapture, didCaptureVideoTexture texture: MTLTexture?, timestamp: CMTime) {
        // Call the predict() method, which encodes the neural net's GPU commands,
        // on our own thread. Since NeuralNetwork.predict() can block, so can our
        // thread. That is OK, since any new frames will be automatically dropped
        // while the serial dispatch queue is blocked.
        if let texture = texture {
            predict(texture: texture)
        }
    }
    
    func videoCapture(_ capture: VideoCapture, didCapturePhotoTexture texture: MTLTexture?, previewImage: UIImage?) {
        // not implemented
    }
    
    //实现代理方法
    func getDocumentURL(_ outputFileURL: URL) {
        self.documentURL = outputFileURL;
    }
}

