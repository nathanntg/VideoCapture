//
//  ArduinoIO.swift
//  VideoCapture
//
//  Created by Nathan Perkins on 7/1/15.
//  Copyright © 2015 GardnerLab. All rights reserved.
//

import Foundation
import ORSSerial

let kTimeoutDuration: NSTimeInterval = 0.5

private enum ArduinoIOState {
    case Closed
    case Opened
    case WaitingToOpen
    //case WaitingToClose
    case Error
    case Uninitialized
}

private enum ArduinoIORequest {
    case SketchInitialize
    case ReadDigital(Int, (Bool?) -> Void)
    case ReadAnalog(Int, (UInt8?) -> Void)
}

enum ArduinoIOError: ErrorType {
    case UnknownError
    case UnableToOpenPath
    case PortNotOpen
    case InvalidPin
    case InvalidMode // invalid pin mode
    case InvalidValue
}

enum ArduinoIOSketch: CustomStringConvertible {
    case Unknown
    case IO
    case EncoderIO
    case ServoEncoderIO
    case MotorShield1
    case MotorShield2
    
    var description: String {
        switch self {
        case .Unknown: return "Unknown"
        case .IO: return "Analog & Digital I/O (adio.pde)"
        case .EncoderIO: return "Analog & Digital I/O + Encoder (arioe.pde)"
        case .ServoEncoderIO: return "Analog & Digital I/O + Encoder + Servos (arioes.pde)"
        case .MotorShield1: return "Motor Shield V1"
        case .MotorShield2: return "Motor Shield V2"
        }
    }
}

enum ArduinoIOQueue {
    case Request(ORSSerialRequest)
    case Send(NSData)
}

enum ArduinoIOPin: Int, CustomStringConvertible {
    case Unassigned = -1
    case Input = 0
    case Output = 1
    
    var description: String {
        switch self {
        case .Unassigned: return "Unassigned"
        case .Input: return "Input"
        case .Output: return "Output"
        }
    }
}

enum ArduinoIODevice {
    case Detached
    case Attached
}


protocol ArduinoIODelegate {
    //func arduinoStateChangedFrom(oldState: ArduinoIOState, newState: ArduinoIOState)
    
    func arduinoError(message: String, isPermanent: Bool)
}

class ArduinoIO: NSObject, ORSSerialPortDelegate {
    // delegate
    var delegate: ArduinoIODelegate?
    
    // serial port
    private(set) var serial: ORSSerialPort? {
        didSet {
            oldValue?.delegate = nil
            serial?.delegate = self
        }
    }
    
    // is port open
    private var state: ArduinoIOState = .Uninitialized {
        didSet {
            //self.delegate?.arduinoStateChangedFrom(oldValue, newState: state)
        }
    }
    
    // sketch id
    var sketch = ArduinoIOSketch.Unknown
    
    // board information
    private var pins = [ArduinoIOPin](count: 70, repeatedValue: ArduinoIOPin.Unassigned) // 0 and 1 are invalid pins
    private var servos = [ArduinoIODevice](count: 69, repeatedValue: ArduinoIODevice.Detached)
    private var encoders = [ArduinoIODevice](count: 3, repeatedValue: ArduinoIODevice.Detached)
    private var motors = [UInt8](count: 4, repeatedValue: UInt8(0))
    private var steppers = [UInt8](count: 2, repeatedValue: UInt8(0))
    
    lazy private var cbEndOfRequest: (NSData?) -> Bool = { (d: NSData?) -> Bool in
        guard let data = d else {
            return false
        }
        if data.length < 3 {
            return false
        }
        if let s = NSString(data: data, encoding: NSASCIIStringEncoding) {
            let str = s as String
            return str.hasSuffix("\r\n")
        }
        return false
    }
    
    // used to hold requests while waiting to open
    private var pendingConnection: [ArduinoIOQueue] = []
    private var requestInfo = [Int: ArduinoIORequest]()
    private var requestInfoId = 1
    
    
    init(serial: ORSSerialPort) {
        super.init()
        
        // set delegate
        serial.delegate = self
        
        // store and open
        self.serial = serial
        self.open()
    }
    
    deinit {
        // close
        close()
    }
    
    convenience init(path: String) throws {
        if let port = ORSSerialPort(path: path) {
            self.init(serial: port)
            return
        }
        throw ArduinoIOError.UnableToOpenPath
    }
    
    private func send(data: NSData, withRequest req: ArduinoIORequest) {
        let num = requestInfoId++
        requestInfo[num] = req
        
        // send request
        let serialReq = ORSSerialRequest(dataToSend: data, userInfo: num as AnyObject, timeoutInterval: kTimeoutDuration, responseEvaluator: cbEndOfRequest)
        send(serialReq)
    }
    
    private func send(req: ORSSerialRequest) {
        if state == .Opened {
            if let serialPort = serial {
                serialPort.sendRequest(req)
            }
        }
        else if state == .WaitingToOpen {
            pendingConnection.append(ArduinoIOQueue.Request(req))
        }
    }
    
    private func send(data: NSData) {
        if state == .Opened {
            if let serialPort = serial {
                serialPort.sendData(data)
            }
        }
        else if state == .WaitingToOpen {
            pendingConnection.append(ArduinoIOQueue.Send(data))
        }
    }
    
    private func open() {
        guard state == .Uninitialized else {
            return
        }
        guard let serialPort = serial else {
            return
        }
        
        // open serial port
        serialPort.baudRate = 115200
        serialPort.open()
        
        // set waiting to open state
        state = .WaitingToOpen
        
        // setup timer
        NSTimer.scheduledTimerWithTimeInterval(3.0, target: self, selector: "completeOpen:", userInfo: nil, repeats: false)
    }
    
    /// Opening process takes 2~6 seconds. Inital requests are held until Arduino is online.
    func completeOpen(timer: NSTimer!) {
        guard self.state == .WaitingToOpen else {
            return
        }
        
        NSLog("Arduino open")
        
        // set state to opened
        state = .Opened
        
        // send request to complete opening process
        let data = "99".dataUsingEncoding(NSASCIIStringEncoding)!
        send(data, withRequest: ArduinoIORequest.SketchInitialize)
    }
    
    private func runPendingConnectionQueue() {
        guard let serialPort = serial else {
            return
        }
        guard self.state == .Opened else {
            pendingConnection.removeAll()
            return
        }
        
        
        // clear pending requests
        for entry in pendingConnection {
            switch entry {
            case ArduinoIOQueue.Send(let data):
                serialPort.sendData(data)
            case ArduinoIOQueue.Request(let req):
                serialPort.sendRequest(req)
            }
        }
        pendingConnection.removeAll()
    }
    
    func canInteract() -> Bool {
        return state == .Opened || state == .WaitingToOpen
    }
    
    func isOpen() -> Bool {
        return state == .Opened
    }
    
    func close() {
        switch state {
        case .Closed, .Error:
            return
        case .Uninitialized:
            state = .Closed
            return
        case .Opened:
            // leave in a good state
            for i in 2...69 {
                do {
                    switch pins[i] {
                    case .Unassigned: continue
                    case .Output:
                        try writeTo(i, digitalValue: false)
                    case .Input:
                        try setPinMode(i, to: ArduinoIOPin.Output)
                        try writeTo(i, digitalValue: false)
                    }
                }
                catch {
                    break
                }
            }
            
            serial?.close()
            serial = nil
            state = .Closed
            
            return
        case .WaitingToOpen:
            serial?.close()
            serial = nil
            state = .Closed
            return
        }
    }
    
    // MARK: - Interface
    
    private func isValidPin(pin: Int) -> Bool {
        return pin >= 2 && pin <= 69
    }
    
    func setPinMode(pin: Int, to: ArduinoIOPin) throws {
        guard canInteract() else {
            throw ArduinoIOError.PortNotOpen
        }
        guard isValidPin(pin) else {
            throw ArduinoIOError.InvalidPin
        }
        guard to != .Unassigned else {
            throw ArduinoIOError.InvalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.PortNotOpen
        }
        
        NSLog("ARDUINO CONFIG \(pin): \(to)")
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [48, 97 + UInt8(pin), 48 + UInt8(to.rawValue)]
        let data = NSData(bytes: dataBytes, length: dataBytes.count)
        send(data)
        
        // set the internal representation
        pins[pin] = to
        
        // TODO: potentially dettach servo
    }
    
    func getPinMode(pin: Int) -> ArduinoIOPin {
        if pin >= 2 && pin <= 69 {
            return pins[pin]
        }
        return .Unassigned
    }
    
    func writeTo(pin: Int, digitalValue: Bool) throws {
        guard canInteract() else {
            throw ArduinoIOError.PortNotOpen
        }
        guard isValidPin(pin) else {
            throw ArduinoIOError.InvalidPin
        }
        guard pins[pin] == .Output else {
            throw ArduinoIOError.InvalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.PortNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [50, 97 + UInt8(pin), 48 + UInt8(digitalValue ? 1 : 0)]
        let data = NSData(bytes: dataBytes, length: dataBytes.count)
        send(data)
        
        NSLog("ARDUINO WRITE \(pin): \(digitalValue)")
    }
    
    func readDigitalValueFrom(pin: Int, andExecute cb: (Bool?) -> Void) throws {
        guard canInteract() else {
            throw ArduinoIOError.PortNotOpen
        }
        guard isValidPin(pin) else {
            throw ArduinoIOError.InvalidPin
        }
        guard pins[pin] == .Input else {
            throw ArduinoIOError.InvalidMode
        }
        guard nil != serial else {
            throw ArduinoIOError.PortNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [49, 97 + UInt8(pin)]
        let data = NSData(bytes: dataBytes, length: dataBytes.count)
        send(data, withRequest: ArduinoIORequest.ReadDigital(pin, cb))
    }
    
    func writeTo(pin: Int, analogValue: UInt8) throws {
        guard canInteract() else {
            throw ArduinoIOError.PortNotOpen
        }
        guard (pin >= 2 && pin <= 13) || (pin >= 44 && pin <= 46) else {
            throw ArduinoIOError.InvalidPin
        }
        guard pins[pin] == .Output else {
            throw ArduinoIOError.InvalidMode 
        }
        guard nil != serial else {
            throw ArduinoIOError.PortNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [52, 97 + UInt8(pin), analogValue]
        let data = NSData(bytes: dataBytes, length: dataBytes.count)
        send(data)
        
        NSLog("ARDUINO WRITE \(pin): \(analogValue)")
    }
    
    func readAnalogValueFrom(pin: Int, andExecute cb: (UInt8?) -> Void) throws {
        guard canInteract() else {
            throw ArduinoIOError.PortNotOpen
        }
        guard pin >= 0 && pin <= 15 else {
            throw ArduinoIOError.InvalidPin
        }
//        guard pins[pin] == .Input else {
//            throw ArduinoIOError.InvalidMode
//        }
        guard nil != serial else {
            throw ArduinoIOError.PortNotOpen
        }
        
        // build data to change pin mode
        let dataBytes: [UInt8] = [51, 97 + UInt8(pin)]
        let data = NSData(bytes: dataBytes, length: dataBytes.count)
        send(data, withRequest: ArduinoIORequest.ReadAnalog(pin, cb))
    }
    
    // MARK: - ORSSerialPortDelegate
    
    func serialPortWasOpened(serialPort: ORSSerialPort) {
        NSLog("SerialPort \(serialPort) was opened")
    }
    
    func serialPortWasClosed(serialPort: ORSSerialPort) {
        NSLog("SerialPort \(serialPort) was closed")
    }
    
    func serialPort(serialPort: ORSSerialPort, didReceiveData data: NSData) {
        if let string = NSString(data: data, encoding: NSUTF8StringEncoding) {
            //self.receivedDataTextView.textStorage?.mutableString.appendString(string as String)
            //self.receivedDataTextView.needsDisplay = true
            NSLog("SerialPort \(serialPort) received \(string)")
        }
    }
    
    func serialPort(serialPort: ORSSerialPort, didReceiveResponse responseData: NSData, toRequest request: ORSSerialRequest) {
        guard let info = request.userInfo, let reqId = info as? Int, let reqType = requestInfo[reqId] else {
            return
        }
        
        // remove value
        requestInfo.removeValueForKey(reqId)
        
        // convert to NSString
        guard let s = NSString(data: responseData, encoding: NSASCIIStringEncoding) else {
            return
        }
        
        let dataAsString: String = (s as String).stringByTrimmingCharactersInSet(NSCharacterSet.newlineCharacterSet())
        
        switch reqType {
        case .SketchInitialize:
            // get sketch identifier
            switch dataAsString {
            case "0": sketch = .IO
            case "1": sketch = .EncoderIO
            case "2": sketch = .ServoEncoderIO
            case "3": sketch = .MotorShield1
            case "4": sketch = .MotorShield2
            default: sketch = .Unknown
            }
            
            // log sketch
            NSLog("Arduino Sketch: \(sketch)")
            
            if sketch == .Unknown {
                // send to delegate
                delegate?.arduinoError("Unknown Sketch", isPermanent: true)
                
                // close connection
                close()
            }
            
            // run queue
            runPendingConnectionQueue()
            
        case .ReadDigital(let pin, let cb):
            NSLog("READ \(pin): \(dataAsString)")
            switch dataAsString {
            case "0": cb(false)
            case "1": cb(true)
            default: cb(nil)
            }
        
        case .ReadAnalog(let pin, let cb):
            NSLog("READ \(pin): \(dataAsString)")
            if let val = Int(dataAsString) where val >= 0 && val <= 255 {
                cb(UInt8(val))
            }
            else {
                cb(nil)
            }
        }
    }
    
    func serialPort(serialPort: ORSSerialPort, requestDidTimeout request: ORSSerialRequest) {
        guard let info = request.userInfo, let reqId = info as? Int, let reqType = requestInfo[reqId] else {
            return
        }
        
        // remove value
        requestInfo.removeValueForKey(reqId)
        
        // log it
        NSLog("Arduino Time Out: \(reqType)")
        
        switch reqType {
        case .SketchInitialize:
            // send to delegate
            delegate?.arduinoError("Initialization Timeout", isPermanent: true)
            
            // close connection
            close()
            
        case .ReadAnalog(_, let cb):
            // send to delegate
            delegate?.arduinoError("Timeout \(reqType)", isPermanent: false)
            
            // callback with no value
            cb(nil)
            
        case .ReadDigital(_, let cb):
            // send to delegate
            delegate?.arduinoError("Timeout \(reqType)", isPermanent: false)
            
            // callback with no value
            cb(nil)
        }
    }
    
    func serialPortWasRemovedFromSystem(serialPort: ORSSerialPort) {
        if state == .WaitingToOpen || state == .Opened {
            // send to delegate
            delegate?.arduinoError("Disconnected", isPermanent: true)
        }
        
        // close everything
        serial = nil
        close()
    }
    
    func serialPort(serialPort: ORSSerialPort, didEncounterError error: NSError) {
        NSLog("SerialPort \(serialPort) encountered an error \(error)")
        
        // send to delegate
        delegate?.arduinoError("Error: \(error.localizedDescription)", isPermanent: false)
    }
}