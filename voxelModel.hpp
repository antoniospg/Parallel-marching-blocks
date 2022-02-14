#ifndef VOXELMODEL_HPP
#define VOXELMODEL_HPP

#include <cuda_runtime.h>

#include <iostream>
#include <string>
#include <cstring>

#include "computeTex.cuh"
#include "constants.h"
#include "cuMesh.cuh"
#include "errorHandling.cuh"
#include "genTriangles.cuh"
#include "getActiveBlocks.cuh"
#include "minMaxReduction.cuh"
#include "voxelLoader.hpp"

using namespace std;

class VoxelModel {
 private:
  VoxelLoader vl;
  ComputeTex ct;
  int n_x, n_y, n_z;

 public:
  VoxelModel(string path) : vl(path), ct(vl.pData, vl.n_x, vl.n_y, vl.n_z) {
    n_x = vl.n_x, n_y = vl.n_y, n_z = vl.n_z;
    int n = n_x * n_y * n_z;

    cudaMemcpyToSymbol(d_neighbourMappingTable, neighbourMappingTable,
                       12 * 4 * sizeof(int));

    // First Kernel Launch
    int2* d_blockMinMax;

    dim3 block_size = {8, 8, 8};
    dim3 grid_size = {(n_x + block_size.x - 1) / block_size.x,
                      (n_y + block_size.y - 1) / block_size.y,
                      (n_z + block_size.z - 1) / block_size.z};
    int num_blocks = grid_size.x * grid_size.y * grid_size.z;

    cudaMalloc(&d_blockMinMax, num_blocks * sizeof(int2));
    blockReduceMinMaxWrapper(ct.texObj, n, d_blockMinMax, grid_size,
                             block_size);
    cudaDeviceSynchronize();

    // Debug First Kernel
    int2* h_blockMinMax = new int2[num_blocks];
    cudaMemcpy(h_blockMinMax, d_blockMinMax, num_blocks * sizeof(int2),
               cudaMemcpyDeviceToHost);

    cout << "Min max Kernel : " << endl;
    for (int i = 0; i < num_blocks; i++) {
      cout << "min : " << h_blockMinMax[i].x << " max : " << h_blockMinMax[i].y
           << endl;
    }

    // Second Kernel Launch
    int* h_activeBlkNum = new int[num_blocks];
    memset(h_activeBlkNum, -1, num_blocks * sizeof(int));

    int* d_activeBlkNum;
    int* d_numActiveBlocks;

    cudaMalloc(&d_activeBlkNum, num_blocks * sizeof(int));
    cudaMalloc(&d_numActiveBlocks, num_blocks * sizeof(int));

    cudaMemcpy(d_activeBlkNum, h_activeBlkNum, num_blocks * sizeof(int),
               cudaMemcpyHostToDevice);

    int block_size2 = 128;
    int grid_size2 = (num_blocks + block_size2 - 1) / block_size2;

    getActiveBlocksWrapper(d_blockMinMax, num_blocks, d_activeBlkNum,
                           d_numActiveBlocks, grid_size2, block_size2);
    cudaDeviceSynchronize();

    int* d_numActiveBlk = d_numActiveBlocks +1;

    // Debug second kernel
    uint numActiveBlk = -1;
    cudaMemcpy(&numActiveBlk, d_numActiveBlk, sizeof(int),
               cudaMemcpyDeviceToHost);
    cout << "    " << numActiveBlk << endl;

    cudaMemcpy(h_activeBlkNum, d_activeBlkNum, num_blocks * sizeof(int),
               cudaMemcpyDeviceToHost);

    for (int i = 0; i < 8; i++) cout << h_activeBlkNum[i] << " " << i << endl;

    // Third Kernel Launch
    dim3 block_size3 = block_size;
    int num_blocks3 = block_size3.x * block_size.y + block_size.z;
    dim3 grid_size3 = {numActiveBlk};

    int* d_vertex_offset;
    cudaMalloc(&d_vertex_offset, 3 * n_x * n_y * n_z * sizeof(int));

    generateTrisWrapper(ct.texObj, d_activeBlkNum, d_numActiveBlk, grid_size3,
                        block_size3);
  }
};

#endif
