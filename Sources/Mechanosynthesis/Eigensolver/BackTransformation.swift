//
//  BackTransformation.swift
//
//
//  Created by Philip Turner on 3/11/24.
//

import Accelerate

extension Diagonalization {
  mutating func backTransform(
    bulgeChasingReflectors: [Float]
  ) {
    var rowOffset: Int = .zero
    while rowOffset < problemSize {
      defer { rowOffset += blockSize }
      
      var blockStart = (problemSize - 1) / blockSize * blockSize
      while blockStart >= 0 {
        let blockEnd = min(blockStart + blockSize, problemSize)
        defer { blockStart -= blockSize }
        
        // Load the sweep into the cache.
        // TODO: Start each sweep's elements at the corresponding diagonal entry.
        var sweepCache = [Float](
          repeating: .zero, count: 2 * blockSize * blockSize)
        for sweepID in blockStart..<blockEnd {
          let rowID: Int = sweepID + rowOffset + 1
          guard rowID < problemSize else {
            continue
          }
          
          let sweepMemoryOffset = sweepID * problemSize + rowID
          let sweepCacheOffset = (sweepID - blockStart) * (2 * blockSize)
          
          let nextRowID = min(rowID + blockSize, problemSize)
          let dotProductCount = nextRowID - rowID
          for elementID in 0..<dotProductCount {
            let matrixAddress = sweepMemoryOffset + elementID
            let matrixValue = bulgeChasingReflectors[matrixAddress]
            sweepCache[sweepCacheOffset + elementID] = matrixValue
          }
        }
        
        // Pad this loop to the cache dimension.
        for sweepID in (blockStart..<blockStart + blockSize).reversed() {
          let rowID: Int = sweepID + rowOffset + 1
          guard rowID < problemSize else {
            continue
          }
          
          let sweepCacheOffset = (sweepID - blockStart) * (2 * blockSize)
          let nextRowID = min(rowID + blockSize, problemSize)
          let dotProductCount = nextRowID - rowID
          
          // Back-transform the eigenvectors.
          for vectorID in 0..<problemSize {
            let baseAddress = vectorID * problemSize
            
            var dotProduct: Float = .zero
            for elementID in 0..<dotProductCount {
              let reflectorDatum = sweepCache[sweepCacheOffset + elementID]
              let vectorDatum = eigenvectors[baseAddress + rowID + elementID]
              dotProduct += reflectorDatum * vectorDatum
            }
            for elementID in 0..<dotProductCount {
              let reflectorDatum = sweepCache[sweepCacheOffset + elementID]
              eigenvectors[baseAddress + rowID + elementID] -= reflectorDatum * dotProduct
            }
          }
        }
      }
    }
    
    // Previous implementation, for reference.
    #if false
    for sweepID in (0..<problemSize).reversed() {
      bulgeChasingReflectors.withContiguousStorageIfAvailable {
        let sweep = $0.baseAddress! + sweepID * problemSize
        
        var rowID: Int = sweepID + 1
        while rowID < problemSize {
          let nextRowID = min(rowID + blockSize, problemSize)
          let dotProductCount = nextRowID - rowID
          defer { rowID += blockSize }
          
          // Back-transform the eigenvectors.
          for vectorID in 0..<problemSize {
            let baseAddress = vectorID * problemSize
            
            var dotProduct: Float = .zero
            for elementID in 0..<dotProductCount {
              let reflectorDatum = sweep[rowID + elementID]
              let vectorDatum = eigenvectors[baseAddress + rowID + elementID]
              dotProduct += reflectorDatum * vectorDatum
            }
            for elementID in 0..<dotProductCount {
              let reflectorDatum = sweep[rowID + elementID]
              eigenvectors[baseAddress + rowID + elementID] -= reflectorDatum * dotProduct
            }
          }
        }
      }
    }
    #endif
  }
  
  mutating func backTransform(
    bandFormReflectors: [Float]
  ) {
    var blockStart = (problemSize - blockSize - 1) / blockSize * blockSize
    while blockStart >= 0 {
      // Adjust the loop end, to account for the factorization band offset.
      let blockEnd = min(blockStart + blockSize, problemSize - blockSize)
      defer { blockStart -= blockSize }
      
      // Reverse the order of the reflectors.
      var reflectorBlock = [Float](
        repeating: .zero, count: blockSize * problemSize)
      for rowID in blockStart..<blockEnd {
        var panelRowID = rowID - blockStart
        panelRowID = (blockSize - 1) - panelRowID
        
        for columnID in 0..<problemSize {
          let matrixAddress = rowID * problemSize + columnID
          let panelAddress = panelRowID * problemSize + columnID
          reflectorBlock[panelAddress] = bandFormReflectors[matrixAddress]
        }
      }
      
      // Create the T matrix using the 'WYTransform' API.
      var transformDesc = WYTransformDescriptor()
      transformDesc = WYTransformDescriptor()
      transformDesc.dimension = SIMD2(problemSize, blockSize)
      transformDesc.reflectorBlock = reflectorBlock
      let transform = WYTransform(descriptor: transformDesc)
      
      // V^H A
      var VA = [Float](repeating: .zero, count: problemSize * blockSize)
#if false
      for m in 0..<blockSize {
        for n in 0..<problemSize {
          var dotProduct: Float = .zero
          for k in 0..<problemSize {
            let lhsValue = reflectorBlock[m * problemSize + k]
            let rhsValue = eigenvectors[n * problemSize + k]
            dotProduct += lhsValue * rhsValue
          }
          VA[n * blockSize + m] = dotProduct
        }
      }
#else
      var gemmDesc = GEMMDescriptor()
      gemmDesc.dimension = SIMD3(blockSize, problemSize, problemSize)
      reflectorBlock.withContiguousStorageIfAvailable {
        gemmDesc.leftOperand = $0.baseAddress!
        gemmDesc.leftOperandStride = problemSize
        gemmDesc.leftTransposeState = "T"
      }
      eigenvectors.withContiguousStorageIfAvailable {
        gemmDesc.rightOperand = $0.baseAddress!
        gemmDesc.rightOperandStride = problemSize
      }
      VA.withContiguousMutableStorageIfAvailable {
        gemmDesc.accumulator = $0.baseAddress!
        gemmDesc.accumulatorStride = blockSize
      }
      GEMM(descriptor: gemmDesc)
      withExtendedLifetime(reflectorBlock) { }
      withExtendedLifetime(eigenvectors) { }
#endif
      
      // T^H (V^H A)
      var TVA = [Float](repeating: .zero, count: problemSize * blockSize)
#if false
      for m in 0..<blockSize {
        for n in 0..<problemSize {
          var dotProduct: Float = .zero
          for k in 0..<blockSize {
            let lhsValue = transform.tau[k * blockSize + m]
            let rhsValue = VA[n * blockSize + k]
            dotProduct += lhsValue * rhsValue
          }
          TVA[n * blockSize + m] = dotProduct
        }
      }
#else
      gemmDesc = GEMMDescriptor()
      gemmDesc.dimension = SIMD3(blockSize, problemSize, blockSize)
      transform.tau.withContiguousStorageIfAvailable {
        gemmDesc.leftOperand = $0.baseAddress!
        gemmDesc.leftOperandStride = blockSize
      }
      VA.withContiguousStorageIfAvailable {
        gemmDesc.rightOperand = $0.baseAddress!
        gemmDesc.rightOperandStride = blockSize
      }
      TVA.withContiguousMutableStorageIfAvailable {
        gemmDesc.accumulator = $0.baseAddress!
        gemmDesc.accumulatorStride = blockSize
      }
      GEMM(descriptor: gemmDesc)
      withExtendedLifetime(transform.tau) { }
      withExtendedLifetime(VA) { }
#endif
      
      // V (T^H V^H A)
#if false
      for m in 0..<problemSize {
        for n in 0..<problemSize {
          var dotProduct: Float = .zero
          for k in 0..<blockSize {
            let lhsValue = reflectorBlock[k * problemSize + m]
            let rhsValue = TVA[n * blockSize + k]
            dotProduct += lhsValue * rhsValue
          }
          eigenvectors[n * problemSize + m] -= dotProduct
        }
      }
#else
      gemmDesc = GEMMDescriptor()
      gemmDesc.dimension = SIMD3(problemSize, problemSize, blockSize)
      gemmDesc.productScale = -1
      gemmDesc.accumulatorScale = 1
      reflectorBlock.withContiguousStorageIfAvailable {
        gemmDesc.leftOperand = $0.baseAddress!
        gemmDesc.leftOperandStride = problemSize
      }
      TVA.withContiguousStorageIfAvailable {
        gemmDesc.rightOperand = $0.baseAddress!
        gemmDesc.rightOperandStride = blockSize
      }
      eigenvectors.withContiguousMutableStorageIfAvailable {
        gemmDesc.accumulator = $0.baseAddress!
        gemmDesc.accumulatorStride = problemSize
      }
      GEMM(descriptor: gemmDesc)
      withExtendedLifetime(reflectorBlock) { }
      withExtendedLifetime(TVA) { }
#endif
    }
  }
}
