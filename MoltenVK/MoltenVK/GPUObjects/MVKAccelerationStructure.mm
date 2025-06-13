/*
 * MVKAccelerationStructure.mm
 *
 * Copyright (c) 2015-2023 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKDevice.h"
#include "MVKBuffer.h"
#include "MVKAccelerationStructure.h"

#include <Metal/Metal.h>


static MTLAttributeFormat mvkMTLAttributeFormatFromVkFormatForAccelerationStructures(VkFormat format)
{
    switch (format) {
        case VK_FORMAT_R32G32B32A32_SFLOAT:
            return MTLAttributeFormatFloat4;
        case VK_FORMAT_R32G32B32_SFLOAT:
            return MTLAttributeFormatFloat3;
        case VK_FORMAT_R32G32_SFLOAT:
            return MTLAttributeFormatFloat2;
        case VK_FORMAT_R32_SFLOAT:
            return MTLAttributeFormatFloat;
        case VK_FORMAT_R16G16B16A16_SFLOAT:
            return MTLAttributeFormatHalf4;
        case VK_FORMAT_R16G16B16_SFLOAT:
            return MTLAttributeFormatHalf3;
        case VK_FORMAT_R16G16_SFLOAT:
            return MTLAttributeFormatHalf2;
        case VK_FORMAT_R16_SFLOAT:
            return MTLAttributeFormatHalf;
        default:
            return MTLAttributeFormatInvalid;
    }
}


#pragma mark -
#pragma mark MVKAcceleration Structure

id<MTLAccelerationStructure> MVKAccelerationStructure::getMTLAccelerationStructure()
{
    return _accelerationStructure;
}
    
MTLAccelerationStructureDescriptor* MVKAccelerationStructure::populateMTLDescriptor(MVKDevice* device,
                                                                                    const VkAccelerationStructureBuildGeometryInfoKHR& buildInfo,
                                                                                    const VkAccelerationStructureBuildRangeInfoKHR* rangeInfos,
                                                                                    const uint32_t* maxPrimitiveCounts)
{
    MTLAccelerationStructureDescriptor* descriptor = nullptr;

    switch (buildInfo.type)
    {
        default:
            break; // TODO: throw error
        case VK_ACCELERATION_STRUCTURE_TYPE_GENERIC_KHR:
        {
            // TODO: should building generic not be allowed?
            // https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VkAccelerationStructureTypeKHR.html
        } break;

        case VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR:
        {
            MTLPrimitiveAccelerationStructureDescriptor* primitive = [MTLPrimitiveAccelerationStructureDescriptor new];

            NSMutableArray* geoms = [NSMutableArray arrayWithCapacity:buildInfo.geometryCount];
            for (uint32_t i = 0; i < buildInfo.geometryCount; i++)
            {
                // TODO: buildInfo.ppGeometries

                const VkAccelerationStructureGeometryKHR& geom = buildInfo.pGeometries[i];
                switch (geom.geometryType)
                {
                    default:
                        break;

                    case VK_GEOMETRY_TYPE_INSTANCES_KHR:
                        break;
                    
                    case VK_GEOMETRY_TYPE_TRIANGLES_KHR:
                    {
                        const VkAccelerationStructureGeometryTrianglesDataKHR& triangleData = geom.geometry.triangles;

                        
                        MTLAccelerationStructureTriangleGeometryDescriptor* geometryTriangles = [MTLAccelerationStructureTriangleGeometryDescriptor new];

                        geometryTriangles.vertexStride = triangleData.vertexStride;
                        geometryTriangles.indexType = mvkMTLIndexTypeFromVkIndexType(triangleData.indexType);
                        geometryTriangles.vertexFormat = mvkMTLAttributeFormatFromVkFormatForAccelerationStructures(triangleData.vertexFormat);


                        if (rangeInfos) {

                            if (triangleData.maxVertex == 0) {
                                break;
                            }

                            uint64_t vertexBDA = triangleData.vertexData.deviceAddress;
                            uint64_t indexBDA = triangleData.indexData.deviceAddress;
                            uint64_t transformBDA = triangleData.transformData.deviceAddress;

                            MVKBuffer* mvkVertexBuffer = device->getBufferAtAddress(vertexBDA);
                            MVKBuffer* mvkIndexBuffer = device->getBufferAtAddress(indexBDA);
                            MVKBuffer* mvkTransformBuffer = device->getBufferAtAddress(transformBDA);

                            // TODO: should validate that buffer->getMTLBufferOffset is a multiple of vertexStride. This could cause issues
                            NSUInteger vbOffset = (vertexBDA - mvkVertexBuffer->getMTLBufferGPUAddress()) + mvkVertexBuffer->getMTLBufferOffset();
                            NSUInteger ibOffset = 0;
                            NSUInteger tfOffset = 0;
                            // Utilize range information during build time
                            geometryTriangles.vertexBuffer = mvkVertexBuffer->getMTLBuffer();

                            if (transformBDA && mvkTransformBuffer)
                            {
                                tfOffset = (transformBDA - mvkTransformBuffer->getMTLBufferGPUAddress()) + mvkTransformBuffer->getMTLBufferOffset();
                                geometryTriangles.transformationMatrixBuffer = mvkTransformBuffer->getMTLBuffer();
                            }

                            bool useIndices = indexBDA && mvkIndexBuffer && triangleData.indexType != VK_INDEX_TYPE_NONE_KHR;
                            if (useIndices)
                            {
                                ibOffset = (indexBDA - mvkIndexBuffer->getMTLBufferGPUAddress()) + mvkIndexBuffer->getMTLBufferOffset();
                                geometryTriangles.indexBuffer = mvkIndexBuffer->getMTLBuffer();
                            }


                            geometryTriangles.triangleCount = rangeInfos[i].primitiveCount;
                            geometryTriangles.transformationMatrixBufferOffset = tfOffset + rangeInfos[i].transformOffset;
                            geometryTriangles.vertexBufferOffset = vbOffset;
                            geometryTriangles.indexBufferOffset = ibOffset + rangeInfos[i].primitiveOffset;

                            if (!useIndices)
                                geometryTriangles.vertexBufferOffset += rangeInfos[i].primitiveOffset + rangeInfos[i].firstVertex * triangleData.vertexStride;
                        }
                        else
                        {
                            // Less information required when computing size

                            //geometryTriangles.vertexBufferOffset = vbOffset;
                            geometryTriangles.triangleCount = maxPrimitiveCounts[i];
                            //geometryTriangles.indexBufferOffset = ibOffset;
                            geometryTriangles.transformationMatrixBufferOffset = 0;
                        }

                        [geoms addObject:geometryTriangles];
                    } break;
                    
                    case VK_GEOMETRY_TYPE_AABBS_KHR:
                    {
                        const VkAccelerationStructureGeometryAabbsDataKHR& aabbData = geom.geometry.aabbs;
                        uint64_t boundingBoxBDA = aabbData.data.deviceAddress;
                        MVKBuffer* mvkBoundingBoxBuffer = device->getBufferAtAddress(boundingBoxBDA);

                        NSUInteger bOffset = (boundingBoxBDA - mvkBoundingBoxBuffer->getMTLBufferGPUAddress()) + mvkBoundingBoxBuffer->getMTLBufferOffset();
                        
                        MTLAccelerationStructureBoundingBoxGeometryDescriptor* geometryAABBs = [MTLAccelerationStructureBoundingBoxGeometryDescriptor new];
                        geometryAABBs.boundingBoxStride = aabbData.stride;
                        geometryAABBs.boundingBoxBuffer = mvkBoundingBoxBuffer->getMTLBuffer();
                        geometryAABBs.boundingBoxBufferOffset = bOffset;

                        if (rangeInfos)
                        {
                            geometryAABBs.boundingBoxCount = rangeInfos[i].primitiveCount;
                            geometryAABBs.boundingBoxBufferOffset += rangeInfos[i].primitiveOffset;
                        }
                        else
                            geometryAABBs.boundingBoxCount = maxPrimitiveCounts[i];

                        [geoms addObject:geometryAABBs];
                    } break;
                }
            }

            primitive.geometryDescriptors = geoms;
            descriptor = primitive;
        } break;
        
        case VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR:
        {
            MTLInstanceAccelerationStructureDescriptor* instance = [MTLInstanceAccelerationStructureDescriptor new];
            // add bottom level acceleration structures

            instance.instanceCount = rangeInfos ? rangeInfos->primitiveCount : *maxPrimitiveCounts;
            instance.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeDefault;
            instance.instanceDescriptorBufferOffset = 0;
            instance.instanceDescriptorStride = sizeof(MTLAccelerationStructureUserIDInstanceDescriptor);

            descriptor = instance;
        } break;
    }

    if (!descriptor)
        return nullptr;

    if (mvkIsAnyFlagEnabled(buildInfo.flags, VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT_KHR))
        descriptor.usage += MTLAccelerationStructureUsageRefit;
    else if (mvkIsAnyFlagEnabled(buildInfo.flags, VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT_KHR))
        descriptor.usage += MTLAccelerationStructureUsagePreferFastBuild;
    else
        descriptor.usage = MTLAccelerationStructureUsageNone;

    return descriptor;
}

VkAccelerationStructureBuildSizesInfoKHR MVKAccelerationStructure::getBuildSizes(MVKDevice* device,
                                                                                 VkAccelerationStructureBuildTypeKHR type,
                                                                                 const VkAccelerationStructureBuildGeometryInfoKHR* info,
                                                                                 const uint32_t* maxPrimitiveCounts)
{
    VkAccelerationStructureBuildSizesInfoKHR vkBuildSizes{};
    
    // TODO: We can't perform host builds, throw an error?
    if (type == VK_ACCELERATION_STRUCTURE_BUILD_TYPE_HOST_KHR)
        return vkBuildSizes;
    
    MTLAccelerationStructureDescriptor* descriptor = populateMTLDescriptor(device, *info, nullptr, maxPrimitiveCounts);

    MVKPhysicalDevice* mtlPhysicalDevice = device->getPhysicalDevice();
    MTLAccelerationStructureSizes sizes = [mtlPhysicalDevice->getMTLDevice() accelerationStructureSizesWithDescriptor:descriptor];
    vkBuildSizes.accelerationStructureSize = sizes.accelerationStructureSize;
    vkBuildSizes.buildScratchSize = sizes.buildScratchBufferSize;
    vkBuildSizes.updateScratchSize = sizes.refitScratchBufferSize;
    
    return vkBuildSizes;
}

uint64_t MVKAccelerationStructure::getMTLSize()
{
    if (!_built) { return 0; }
    return _accelerationStructure.size;
}

MVKAccelerationStructure::MVKAccelerationStructure(MVKDevice* device,
                                                   const VkAccelerationStructureCreateInfoKHR* pCreateInfo) : MVKVulkanAPIDeviceObject(device)
{
    auto accSize = [getMTLDevice() heapAccelerationStructureSizeAndAlignWithSize:pCreateInfo->size];

    MTLHeapDescriptor* heapDescriptor = [MTLHeapDescriptor new];
    heapDescriptor.type = MTLHeapTypePlacement;
    heapDescriptor.storageMode = MTLStorageModePrivate;
    heapDescriptor.size = accSize.size;

    _heap = [getMTLDevice() newHeapWithDescriptor:heapDescriptor];

    _sharedBuffer = (MVKBuffer*) pCreateInfo->buffer;
    _bufferOffset = pCreateInfo->offset;
    _size = pCreateInfo->size;
    _type = pCreateInfo->type;

    // For now all resources will begin at beginning of heap.
    // Ideally we'd get this from an AccelerationStructureHeapManager?
    NSUInteger heapOffset = 0;

    _accelerationStructure = [_heap newAccelerationStructureWithSize: accSize.size
                                                              offset: heapOffset];

    MTLResourceOptions options = MTLResourceStorageModePrivate;
    _buffer = [_heap newBufferWithLength: _size
                                 options: options
                                  offset: heapOffset];

    [_accelerationStructure makeAliasable];
    [_buffer makeAliasable];
}

void MVKAccelerationStructure::encodeCopyToSharedBuffer(MVKCommandEncoder* cmdEncoder)
{
    id<MTLBlitCommandEncoder> blitEncoder = cmdEncoder->getMTLBlitEncoder(kMVKCommandUseCopyAccelerationStructureToMemory);

    [blitEncoder copyFromBuffer: _buffer
                   sourceOffset: 0
                       toBuffer: _sharedBuffer->getMTLBuffer()
              destinationOffset: 0
                           size: _size];
}

void MVKAccelerationStructure::addBLASHandle(MVKAccelerationStructure* blasHandle)
{
    _blasHandles.push_back(blasHandle);
}

MVKArrayRef<MVKAccelerationStructure*> MVKAccelerationStructure::getBLASHandles()
{
    return MVKArrayRef<MVKAccelerationStructure*>(_blasHandles.data(), _blasHandles.size());
}

uint64_t MVKAccelerationStructure::getDeviceAddress() const
{
    return [_buffer gpuAddress];
}

void MVKAccelerationStructure::destroy()
{
    [_heap release];
    _built = false;
}
