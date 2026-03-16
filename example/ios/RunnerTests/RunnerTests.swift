import Flutter
import UIKit
import XCTest

// If your plugin has been explicitly set to "type: .dynamic" in the Package.swift,
// you will need to add your plugin as a dependency of RunnerTests within Xcode.

@testable import metronome

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = MetronomePlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String, "iOS " + UIDevice.current.systemVersion)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testMetronomeTicksAndBpmChange() {
    let wavData = makeWavData(sampleRate: 44100, durationMs: 100)
    let metronome = Metronome(
      mainFileBytes: wavData,
      accentedFileBytes: wavData,
      bpm: 120,
      timeSignature: 4,
      volume: 0.1,
      sampleRate: 44100
    )

    let tickHandler = EventTickHandler()
    var ticks: [Int] = []
    _ = tickHandler.onListen(withArguments: nil, eventSink: { event in
      if let tick = event as? Int {
        ticks.append(tick)
      }
    })

    metronome.enableTickCallback(_eventTickSink: tickHandler)

    let tickExpectation = expectation(description: "receives ticks")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      metronome.play()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      metronome.setBPM(bpm: 200)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      if ticks.count >= 3 {
        tickExpectation.fulfill()
      }
    }

    waitForExpectations(timeout: 1.5)
    XCTAssertEqual(ticks.first, 0)
  }

  private func makeWavData(sampleRate: Int, durationMs: Int) -> Data {
    let numSamples = max(1, sampleRate * durationMs / 1000)
    var pcm = [Int16](repeating: 0, count: numSamples)
    pcm[0] = Int16.max / 4

    let dataSize = numSamples * MemoryLayout<Int16>.size
    var data = Data()
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(UInt32(36 + dataSize).littleEndianData)
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // "fmt "
    data.append(UInt32(16).littleEndianData) // Subchunk1Size
    data.append(UInt16(1).littleEndianData) // AudioFormat PCM
    data.append(UInt16(1).littleEndianData) // NumChannels
    data.append(UInt32(sampleRate).littleEndianData)
    data.append(UInt32(sampleRate * 2).littleEndianData) // ByteRate
    data.append(UInt16(2).littleEndianData) // BlockAlign
    data.append(UInt16(16).littleEndianData) // BitsPerSample
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    data.append(UInt32(dataSize).littleEndianData)

    pcm.withUnsafeBufferPointer { buffer in
      let raw = Data(buffer: buffer)
      data.append(raw)
    }
    return data
  }
}

private extension FixedWidthInteger {
  var littleEndianData: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: MemoryLayout<Self>.size)
  }
}
