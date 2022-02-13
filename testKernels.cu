#include <assert.h>

#include <iostream>

#include "computeTex.cuh"
#include "constants.h"
#include "errorHandling.cuh"
#include "getActiveBlocks.cuh"
#include "minMaxReduction.cuh"
#include "voxelLoader.hpp"

#define WP_SIZE 32
typedef uchar3 bool3;

__constant__ int d_edgeTable[256];
__constant__ int d_triTable[256][16];
__constant__ int d_neighbourMappingTable[12][4];

__device__ __inline__ float3 interpolate3(uint3 pos1, uint3 pos2, int w1,
                                          int w2) {
  return float3{(float)(pos1.x * w1 + pos2.x * w2) / (w1 + w2),
                (float)(pos1.y * w1 + pos2.y * w2) / (w1 + w2),
                (float)(pos1.z * w1 + pos2.z * w2) / (w1 + w2)};
}

__device__ int3 sampleVolume_old(uint3 pos, volatile int* shem,
                                 cudaTextureObject_t tex, float3* vertices) {
  int tid_block = threadIdx.x + blockDim.x * threadIdx.y +
                  blockDim.x * blockDim.y * threadIdx.z;

  // Neighbours in each direction
  uint offsets[3] = {(threadIdx.x + 1) + blockDim.x * threadIdx.y +
                         blockDim.x * blockDim.y * threadIdx.z,
                     threadIdx.x + blockDim.x * (threadIdx.y + 1) +
                         blockDim.x * blockDim.y * threadIdx.z,
                     threadIdx.x + blockDim.x * threadIdx.y +
                         blockDim.x * blockDim.y * (threadIdx.z + 1)};

  bool bound_condition[3] = {threadIdx.x + 1 < blockDim.x,
                             threadIdx.y + 1 < blockDim.x,
                             threadIdx.z + 1 < blockDim.x};

  uint3 next_vertices[3] = {uint3{pos.x + 1, pos.y, pos.z},
                            uint3{pos.x, pos.y + 1, pos.z},
                            uint3{pos.x, pos.y, pos.z + 1}};

  int next_voxels[3] = {0, 0, 0};
  int num_vertices = 0;
  int3 indices = int3{0, 0, 0};

  // Check if vertex its out of boundaries
#pragma unroll
  for (size_t i = 0; i < 3; i++) {
    if (bound_condition[i])
      next_voxels[i] = shem[offsets[i]];
    else
      next_voxels[i] = tex3D<int>(tex, next_vertices[i].x, next_vertices[i].y,
                                  next_vertices[i].z);
  }

#pragma unroll
  for (size_t i = 0; i < 3; i++) {
    int w1 = shem[tid_block];
    int w2 = next_voxels[i];
    if (w1 == 0 && w2 == 0) continue;

    vertices[i] = interpolate3(pos, next_vertices[i], w1, w2);
    num_vertices++;
  }

  if (num_vertices == 1) indices.x = 1, indices.y = 0, indices.z = 0;
  if (num_vertices == 2) indices.x = 1, indices.y = 1, indices.z = 0;
  if (num_vertices == 3) indices.x = 1, indices.y = 1, indices.z = 1;

  return indices;
}

__device__ bool3 get_active_edges(uint3 pos, volatile int* shem) {
  int tid_block = threadIdx.x + blockDim.x * threadIdx.y +
                  blockDim.x * blockDim.y * threadIdx.z;
  // Neighbours in each direction
  uint offsets[3] = {(threadIdx.x + 1) + blockDim.x * threadIdx.y +
                         blockDim.x * blockDim.y * threadIdx.z,
                     threadIdx.x + blockDim.x * (threadIdx.y - 1) +
                         blockDim.x * blockDim.y * threadIdx.z,
                     threadIdx.x + blockDim.x * threadIdx.y +
                         blockDim.x * blockDim.y * (threadIdx.z + 1)};

  bool xyz_edges[3] = {0, 0, 0};

#pragma unroll
  for (size_t i = 0; i < 3; i++) {
    if (shem[tid_block] == 0 || offsets[i] < 0 ||
        offsets[i] > blockDim.x * blockDim.y * blockDim.z)
      xyz_edges[i] = false;
    else
      xyz_edges[i] = shem[offsets[i]] != 0;
  }

  return bool3{xyz_edges[0], xyz_edges[1], xyz_edges[2]};
}

__device__ __inline__ bool get_neighbor_mapping(int edge,
                                                volatile bool3* shem) {
  int edge_offset[4] = {
      d_neighbourMappingTable[edge][0], d_neighbourMappingTable[edge][2],
      d_neighbourMappingTable[edge][1], d_neighbourMappingTable[edge][3]};

  int shem_offset = (threadIdx.x + edge_offset[0]) +
                    blockDim.x * (threadIdx.y + edge_offset[1]) +
                    blockDim.x * blockDim.y * (threadIdx.z + edge_offset[2]);

  if (edge_offset[3] == 0) return shem[shem_offset].x;
  if (edge_offset[3] == 1) return shem[shem_offset].y;
  if (edge_offset[3] == 2) return shem[shem_offset].z;
  return -1;
}

__global__ void generateTris(cudaTextureObject_t tex, int* activeBlocks,
                             int* numActiveBlocks) {
  uint numBlk = *numActiveBlocks;
  int block_id = activeBlocks[blockIdx.x];
  int tid_block = threadIdx.x + blockDim.x * threadIdx.y +
                  blockDim.x * blockDim.y * threadIdx.z;
  int wid = tid_block / WP_SIZE;
  int lane = tid_block % WP_SIZE;

  int3 block_pos =
      int3{block_id % 16, (block_id / 16) % (16 * 16), block_id / (16 * 16)};
  uint3 pos = uint3{threadIdx.x + block_pos.x * blockDim.x,
                    threadIdx.y + block_pos.y * blockDim.y + 1,
                    threadIdx.z + block_pos.z * blockDim.z};

  // Multi use shem to store voxel values
  __shared__ int voxels[1024];
  voxels[tid_block] = tex3D<int>(tex, pos.x, pos.y, pos.z);
  __syncthreads();

  bool3 xyz_edges = get_active_edges(pos, voxels);
  if (xyz_edges.x > 0 || xyz_edges.y > 0 || xyz_edges.z > 0)
    printf("%d %d %d ,,,,, %d %d %d \n", pos.x, pos.y, pos.z, xyz_edges.x,
           xyz_edges.y, xyz_edges.z);

  __shared__ bool3 activeEdges[1024];
  activeEdges[tid_block] = xyz_edges;
  __syncthreads();
}

using namespace std;

int main() {
  VoxelLoader vl("sphere.dat");

  cudaMemcpyToSymbol(d_edgeTable, edgeTable, 256 * sizeof(int));
  cudaMemcpyToSymbol(d_triTable, edgeTable, 256 * 16 * sizeof(int));
  cudaMemcpyToSymbol(d_neighbourMappingTable, edgeTable, 12 * 4 * sizeof(int));

  ComputeTex ct(vl.pData, vl.n_x, vl.n_y, vl.n_z);

  int n_x = vl.n_x, n_y = vl.n_y, n_z = vl.n_z;
  int n = n_x * n_y * n_z;

  dim3 block_size = {8, 8, 8};
  dim3 grid_size = {(n_x + block_size.x - 1) / block_size.x,
                    (n_y + block_size.y - 1) / block_size.y,
                    (n_z + block_size.z - 1) / block_size.z};
  int num_blocks = grid_size.x * grid_size.y * grid_size.z;

  int2* h_blockMinMax = new int2[num_blocks];
  int2* g_blockMinMax;
  int* g_h_activeBlkNum;
  int* g_numActiveBlocks;

  cudaMalloc(&g_blockMinMax, num_blocks * sizeof(int2));
  cudaMallocManaged(&g_h_activeBlkNum, num_blocks * sizeof(int));
  cudaMalloc(&g_numActiveBlocks, num_blocks * sizeof(int));

  for (int i = 0; i < num_blocks; i++) g_h_activeBlkNum[i] = -1;

  blockReduceMinMax<<<grid_size, block_size>>>(ct.texObj, n, g_blockMinMax);

  cudaMemcpy(h_blockMinMax, g_blockMinMax, num_blocks * sizeof(int2),
             cudaMemcpyDeviceToHost);

  for (int i = 0; i < num_blocks; i++) {
    cout << "min : " << h_blockMinMax[i].x << " max : " << h_blockMinMax[i].y
         << endl;
  }
  cout << "$$$$$$$$$$$\n";

  int block_size2 = 128;
  int grid_size2 = (num_blocks + block_size2 - 1) / block_size2;
  getActiveBlocks<<<grid_size2, block_size2>>>(
      g_blockMinMax, num_blocks, g_h_activeBlkNum, g_numActiveBlocks);

  int* d_numActiveBlk = g_numActiveBlocks + block_size2 - 1;

  cudaDeviceSynchronize();

  uint numActiveBlk = 0;
  cudaMemcpy(&numActiveBlk, g_numActiveBlocks + block_size2 - 1, sizeof(int),
             cudaMemcpyDeviceToHost);

  dim3 block_size3 = block_size;
  int num_blocks3 = block_size3.x * block_size.y + block_size.z;
  dim3 grid_size3 = {numActiveBlk};

  int* g_vertex_offset;
  cudaMalloc(&g_vertex_offset, 3 * n_x * n_y * n_z * sizeof(int));

  generateTris<<<grid_size3, block_size3>>>(ct.texObj, g_h_activeBlkNum,
                                            d_numActiveBlk);

  for (int i = 0; i < 8; i++)
    cout << g_h_activeBlkNum[i] << " " << h_blockMinMax[i].x << " "
         << h_blockMinMax[i].y << " " << i << endl;
}
