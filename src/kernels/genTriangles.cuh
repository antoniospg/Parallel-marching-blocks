#ifndef GENTRIANGLES_CUH
#define GENTRIANGLES_CUH

#include "cuMesh.cuh"

typedef uchar3 bool3;
typedef uchar4 bool4;

namespace genTriangles {

__device__ __inline__ float3 lerpVertex(int3 pos1, int3 pos2, int v1, int v2);
__device__ __inline__ float3 lerpVertex(float3 pos1, float3 pos2, int v1,
                                        int v2);

__device__ bool3 get_active_edges(int3 pos, volatile int* shem);

__device__ bool3 getVertex(int3 pos, bool3& active_edges,
                           volatile int* shem_voxel,
                           volatile float3* shem_voxel_normals,
                           float3* vertices, float3* normals);

__device__ __inline__ bool get_neighbor_mapping(int edge, volatile bool3* shem);

__device__ __inline__ int warpReduceScan(int val, int laneid);

__device__ int getVertexOffset(int nums);

__device__ int borrowVertex(int3 pos, int edge,
                            volatile int3* vertices_block_id_shem,
                            volatile bool3* active_edges_shem);

__global__ void generateTris(cudaTextureObject_t tex,
                             cudaTextureObject_t texNormal, int* activeBlocks,
                             int* numActiveBlocks, dim3 grid_size,
                             int* block_vertex_offset, int* block_index_offset,
                             vert3* vertices, int3* indices);
__global__ void setGlobal();

__device__ int getCubeidx(int3 pos, volatile int* shem);

int2 generateTrisWrapper(cudaTextureObject_t tex, cudaTextureObject_t texNormal,
                         int* activeBlocks, int* numActiveBlocks,
                         dim3 grid_size3, dim3 block_size3, dim3 grid_size,
                         int isoVal, uint3 nxyz, int* d_block_vertex_offset,
                         int* d_block_index_offset, vert3* d_vertices_ref,
                         int3* d_indices_ref);
};  // namespace genTriangles
#endif
