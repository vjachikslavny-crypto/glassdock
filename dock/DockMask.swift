import CoreGraphics
import Foundation

/// A click-through wallpaper patch. Pixels over the native Dock's foreground stay clear.
enum DockMask {
    private struct Raster {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: CGImage, space: CGColorSpace) {
            width = image.width
            height = image.height
            let w = width, h = height
            var buffer = [UInt8](repeating: 0, count: 4 * w * h)
            let drawn = buffer.withUnsafeMutableBytes { memory -> Bool in
                guard let context = CGContext(data: memory.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: DockMask.format.rawValue)
                else { return false }
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            bytes = buffer
        }

        @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

        @inline(__always) func distance(_ i: Int, _ j: Int) -> Int {
            max(abs(Int(bytes[i]) - Int(bytes[j])), abs(Int(bytes[i+1]) - Int(bytes[j+1])),
                abs(Int(bytes[i+2]) - Int(bytes[j+2])), abs(Int(bytes[i+3]) - Int(bytes[j+3])))
        }
    }

    private struct Edge {
        let row: Int
        let first: Int
        let last: Int
        let strength: Double
    }

    private struct Shelf {
        let left: Int, right: Int, top: Int, bottom: Int
        let radius: Double
    }

    private static let format = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

    // A Dock shelf has two long, parallel, level edges and a mostly smooth fill immediately
    // inside them. Find long runs rather than taking the bounds of all nontransparent pixels:
    // moving icons, tooltips and magnification may extend beyond the shelf.
    private static func edges(_ frame: Raster, scale: CGFloat) -> [Edge] {
        let step = max(2, Int((2 * scale).rounded()))
        let yStep = max(1, Int((0.65 * scale).rounded()))
        let maxGap = max(3, Int(9 * scale) / step)
        let samples = (frame.width - 2 * step) / step
        let minRun = max(8, Int(85 * scale) / step)
        guard samples > minRun && frame.height > 2*yStep else { return [] }
        var results: [Edge] = []
        for y in yStep..<(frame.height-yStep) {
            var runs: [Edge] = []
            var start = 0, last = -1, valid = 0
            var total: Double = 0
            func finish() {
                if valid >= max(8, minRun/2) && valid * 5 >= (last-start+1) * 4 {
                    let new = Edge(row: y, first: (start+1)*step, last: (last+1)*step,
                                   strength: total)
                    if let previous = runs.last, new.first-previous.last < Int(90*scale) {
                        runs[runs.count-1] = Edge(row:y,first:previous.first,last:new.last,
                                                  strength:previous.strength+new.strength)
                    } else { runs.append(new) }
                }
                valid = 0; total = 0
            }
            for j in 0..<samples {
                let x = (j+1)*step
                let up = frame.index(x,y-yStep), down = frame.index(x,y+yStep)
                let delta = frame.distance(up,down)
                let upperChange = max(frame.distance(up,up-step*4), frame.distance(up,up+step*4))
                let lowerChange = max(frame.distance(down,down-step*4), frame.distance(down,down+step*4))
                let horizontal = min(upperChange,lowerChange)
                if delta >= 5 && horizontal <= min(12,delta/2+2) {
                    if valid == 0 { start = j }
                    last = j; valid += 1; total += min(25, Double(delta))
                } else if valid > 0 && j - last > maxGap { finish() }
            }
            if valid > 0 { finish() }
            if let best=runs.max(by: { $0.strength < $1.strength }), best.last-best.first >= minRun*step { results.append(best) }
        }
        return results
    }

    private static func findShelf(_ frame: Raster, scale: CGFloat) -> Shelf? {
        let candidates = edges(frame, scale: scale)
        let minHeight = Int(21 * scale), maxHeight = Int(150 * scale)
        let minWidth = max(Int(95 * scale), frame.width/12)
        var best: (Edge, Edge)?, bestScore = 0.0
        for bottom in candidates where frame.height - bottom.row < Int(32 * scale) {
            for top in candidates {
                let height = bottom.row - top.row
                guard height >= minHeight && height <= maxHeight else { continue }
                let span = min(top.last,bottom.last) - max(top.first,bottom.first)
                guard span > minWidth else { continue }
                let topSpan = top.last-top.first, bottomSpan = bottom.last-bottom.first
                let similarity = Double(span) / Double(max(topSpan,bottomSpan))
                guard similarity > 0.68 else { continue }
                let score = (min(top.strength,bottom.strength) + 0.12*max(top.strength,bottom.strength)) * similarity
                if score > bestScore { best = (top,bottom); bestScore = score }
            }
        }
        guard let (top,bottom) = best else { return nil }
        let height = bottom.row-top.row
        let r = Double(height)*0.25
        let edgeStart = max(top.first,bottom.first), edgeEnd = min(top.last,bottom.last)
        let middle = (top.row + bottom.row)/2
        let search = Int(2*r+6*scale)
        let hop = max(1,Int(scale.rounded()))
        func side(at x: Int, left: Bool) -> Int {
            let lo = max(hop, x - search), hi = min(frame.width-hop-1, x+search)
            guard lo <= hi else { return left ? 0 : frame.width-1 }
            var winner = x
            var high: Double = 0
            for xx in lo...hi {
                var contrast = 0
                for yy in stride(from: middle-height/5, through:middle+height/5, by:hop*2) {
                    let a=frame.index(xx-hop,yy), b=frame.index(xx+hop,yy)
                    contrast += min(75,frame.distance(a,b))
                }
                let predicted = Double(x) + (left ? -r : r)
                let weight = 1.0/(1.0 + abs(Double(xx)-predicted)/max(1,r))
                let score = Double(contrast)*weight
                if score > high { high=score; winner=xx }
            }
            if left && edgeStart < Int(r) { return min(winner,max(0,edgeStart-Int(r))) }
            if !left && frame.width-edgeEnd < Int(r) { return max(winner,min(frame.width-1,edgeEnd+Int(r))) }
            return winner
        }
        let left=side(at:edgeStart,left:true), right=side(at:edgeEnd,left:false)
        guard right-left > minWidth else { return nil }
        return Shelf(left:left,right:right,top:top.row,bottom:bottom.row,radius:r)
    }

    // Take median colours along bands near the top and bottom of the fill. Those bands
    // have no normal-sized app icons. Medians suppress small overlaps from badges and dots.
    private static func palette(_ frame: Raster, shelf: Shelf, row: Int, scale:CGFloat) -> [[Int]] {
        let grid=max(3,Int(5*scale)), span=max(3,Int(10*scale)), hop=max(1,Int(scale))
        let inset = min((shelf.right-shelf.left)/4,Int(shelf.radius))
        var anchors=[[Int]]()
        let y = min(frame.height-1,max(0,row))
        for x in stride(from:shelf.left, through:shelf.right+grid, by:grid) {
            let xx=min(shelf.right-inset,max(shelf.left+inset,x))
            var channels=Array(repeating:[Int](),count:4)
            for sample in stride(from:max(shelf.left,xx-span), through:min(shelf.right,xx+span), by:hop) {
                let i=frame.index(sample,y)
                for c in 0..<4 { channels[c].append(Int(frame.bytes[i+c])) }
            }
            anchors.append(channels.map{ $0.sorted()[$0.count/2] })
        }
        // A large badge can cover the entire short median window. Interpolate across
        // isolated colour outliers only when the shelf on both sides agrees.
        let raw = anchors
        let look = max(2, Int(38*scale) / grid)
        if raw.count > look*2 {
            for n in look..<(raw.count-look) {
                let l=raw[n-look], r=raw[n+look]
                guard (0..<4).allSatisfy({abs(l[$0]-r[$0])<=24}) else { continue }
                let average = (0..<4).map{(l[$0]+r[$0])/2}
                if (0..<4).contains(where:{abs(raw[n][$0]-average[$0])>13}) { anchors[n]=average }
            }
        }
        var result=[[Int]]()
        result.reserveCapacity(shelf.right-shelf.left+1)
        for dx in 0...(shelf.right-shelf.left) {
            let n=dx/grid, remainder=dx%grid, next=min(n+1,anchors.count-1)
            result.append((0..<4).map{ (anchors[n][$0]*(grid-remainder)+anchors[next][$0]*remainder)/grid })
        }
        return result
    }

    static func compose(dock: CGImage, wallpaper: CGImage, scale: CGFloat,
                        onShelf: ((CGRect) -> Void)? = nil) -> CGImage? {
        guard dock.width==wallpaper.width, dock.height==wallpaper.height,
              dock.width>16, dock.height>12, dock.width<=16384, dock.height<=1024,
              scale.isFinite, scale>=0.5, scale<=4,
              let colorSpace=CGColorSpace(name:CGColorSpace.sRGB),
              let frame=Raster(dock,space:colorSpace), let shelf=findShelf(frame,scale:scale),
              let paper=Raster(wallpaper,space:colorSpace) else { return nil }
        let inner = max(3,Int(2.5*scale)), outer = max(2,Int(2*scale))
        let bandTop=shelf.top+inner, bandBottom=shelf.bottom-inner
        guard bandTop < bandBottom else { return nil }
        let upper=palette(frame,shelf:shelf,row:bandTop,scale:scale)
        let lower=palette(frame,shelf:shelf,row:bandBottom,scale:scale)
        let w=frame.width, h=frame.height, span=bandBottom-bandTop
        let left=max(0,shelf.left-outer), right=min(w-1,shelf.right+outer)
        let top=max(0,shelf.top-outer), bottom=min(h-1,shelf.bottom+outer)
        var mask=[UInt8](repeating:0,count:w*h)
        var queue=[Int]()
        queue.reserveCapacity((right-left+1)*(bottom-top+1))
        for y in top...bottom {
            let rowWeight = max(0,min(span,y-bandTop))
            let yDist=min(y-shelf.top,shelf.bottom-y)
            let cornerY = max(0,shelf.radius-Double(yDist))
            let dx = shelf.radius - sqrt(max(0,shelf.radius*shelf.radius - cornerY*cornerY))
            let xMin=Int(Double(shelf.left)+dx), xMax=Int(Double(shelf.right)-dx)
            let a=max(left,xMin-outer), b=min(right,xMax+outer)
            guard a<=b else { continue }
            for x in a...b {
                let k=y*w+x, i=k*4
                let rim = yDist<inner || x<xMin+inner || x>xMax-inner
                if rim {
                    mask[k]=2; queue.append(k); continue
                }
                let j=max(0,min(shelf.right-shelf.left,x-shelf.left))
                var distance=0
                for c in 0..<4 {
                    let value=(upper[j][c]*(span-rowWeight)+lower[j][c]*rowWeight)/span
                    distance=max(distance,abs(value-Int(frame.bytes[i+c])))
                }
                if distance<=8 { mask[k]=1 }
            }
        }
        // Keep the interiors of icons whose colours happen to match the wallpaper.
        // Only shelf colour connected to the perimeter can become a wallpaper patch.
        var next=0
        while next<queue.count {
            let i=queue[next]; next += 1
            if i>=w && mask[i-w]==1 { mask[i-w]=2; queue.append(i-w) }
            if i+w<w*h && mask[i+w]==1 { mask[i+w]=2; queue.append(i+w) }
            if i>0 && mask[i-1]==1 { mask[i-1]=2; queue.append(i-1) }
            if i+1<w*h && mask[i+1]==1 { mask[i+1]=2; queue.append(i+1) }
        }
        // A plain floating rectangle or an Exposé dimmer is not the Dock. An actual
        // shelf has at least Finder and the Trash, with gaps between their silhouettes.
        let middle = (bandTop + bandBottom) / 2
        let guardRange = (shelf.left + inner)...(shelf.right - inner)
        let minimumTile = max(3, Int(3*scale))
        var foregroundCount = 0, run = 0, tileCount = 0
        for x in guardRange {
            if mask[middle*w+x] != 2 {
                run += 1; foregroundCount += 1
                if run == minimumTile { tileCount += 1 }
            } else { run = 0 }
        }
        guard tileCount >= 2, foregroundCount > guardRange.count/15,
              foregroundCount < guardRange.count * 96 / 100 else { return nil }

        // Badges and magnified icons can straddle the hairline on the top edge. If a
        // connected foreground silhouette crosses into the rim, preserve its pixels
        // there too. The ordinary top/bottom outline remains covered between tiles.
        let xGuardMin = shelf.left + Int(shelf.radius), xGuardMax = shelf.right - Int(shelf.radius)
        let inset = max(1, Int(scale))
        let clearSamples = stride(from: 0, to: w, by: max(1,w/24)).filter { frame.bytes[frame.index($0,0)+3] < 4 }.count
        let hasIsolatedMaterial = clearSamples >= 5 && lower[lower.count/2][3] < 240
        if hasIsolatedMaterial {
            // The isolated window carries the exact alpha of the shelf, the shadow and
            // each tile. The shadow reaches well beyond the geometric rounded rectangle.
            // Only its black ink is eligible outside the rim so animation and tooltips
            // passing through the same band keep their coloured and opaque pixels.
            let shadowReach = Int(96*scale)
            let minX = max(0, shelf.left-shadowReach), maxX = min(w-1, shelf.right+shadowReach)
            let minY = max(0, shelf.top-shadowReach), maxY = min(h-1, shelf.bottom+shadowReach)
            let rimTolerance = Int(7*scale)
            for y in minY...maxY {
                let yDist = min(y-shelf.top, shelf.bottom-y)
                let cornerY = max(0, shelf.radius - Double(max(0,yDist)))
                let cornerInset = Int(shelf.radius - sqrt(max(0,shelf.radius*shelf.radius - cornerY*cornerY)))
                let sideL = shelf.left+cornerInset, sideR = shelf.right-cornerInset
                for x in minX...maxX {
                    let k=y*w+x, i=k*4, alpha=Int(frame.bytes[i+3])
                    guard alpha > 0 else { mask[k]=0; continue }
                    let xDist = min(x-sideL,sideR-x)
                    if (xDist < 0 || yDist < 0), alpha < 180,
                       frame.bytes[i] <= 1, frame.bytes[i+1] <= 1, frame.bytes[i+2] <= 1 {
                        mask[k]=2; continue
                    }
                    guard yDist >= -rimTolerance, xDist >= -rimTolerance,
                          min(yDist,xDist) <= rimTolerance else { continue }
                    let j=max(0,min(upper.count-1,x-shelf.left))
                    let floorAlpha = max(upper[j][3],lower[j][3])
                    // The pale outline is only a little more opaque than the fill.
                    // Tiles and running dots crossing it have their own stronger alpha.
                    if alpha > min(246,floorAlpha+14) { mask[k]=0; continue }
                    if xDist < inner || yDist < inner {
                        mask[k]=2
                    } else if mask[k] != 2 {
                        // On a continuous rounded corner the estimate can fall a few
                        // pixels inside the real outline. Its RGB channels rise together.
                        let r=Int(frame.bytes[i])-upper[j][0]
                        let g=Int(frame.bytes[i+1])-upper[j][1]
                        let b=Int(frame.bytes[i+2])-upper[j][2]
                        if max(r,g,b)-min(r,g,b) <= 10 && min(r,g,b) >= -8 { mask[k]=2 }
                    }
                }
            }
        } else if xGuardMin <= xGuardMax && bandTop+inset < bandBottom-inset {
            for x in xGuardMin...xGuardMax {
                if mask[bandTop*w+x] != 2 && mask[(bandTop+inset)*w+x] != 2 {
                    for y in top..<bandTop { mask[y*w+x]=0 }
                }
                if mask[bandBottom*w+x] != 2 && mask[(bandBottom-inset)*w+x] != 2 {
                    for y in (bandBottom+1)...bottom { mask[y*w+x]=0 }
                }
            }
        }
        var output=[UInt8](repeating:0,count:4*w*h)
        output.withUnsafeMutableBytes { out in
            paper.bytes.withUnsafeBytes { input in
                let dest=out.bindMemory(to:UInt32.self), src=input.bindMemory(to:UInt32.self)
                for index in mask.indices where mask[index]==2 { dest[index]=src[index] }
            }
        }
        guard let provider=CGDataProvider(data: Data(output) as CFData) else { return nil }
        onShelf?(CGRect(x:shelf.left, y:shelf.top, width:shelf.right-shelf.left+1, height:shelf.bottom-shelf.top+1))
        return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4*w,
                       space:colorSpace,bitmapInfo:format,provider:provider,decode:nil,shouldInterpolate:false,
                       intent:.defaultIntent)
    }
}
