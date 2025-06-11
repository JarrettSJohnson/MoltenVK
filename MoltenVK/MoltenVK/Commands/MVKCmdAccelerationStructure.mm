/*
 * MVKCmdAccelerationStructure.mm
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

#include "MVKCmdAccelerationStructure.h"
#include "MVKCmdDebug.h"
#include "MVKCommandBuffer.h"
#include "MVKCommandPool.h"
#include "MVKAccelerationStructure.h"

#include <Metal/Metal.h>

#pragma mark -
#pragma mark MVKCmdBuildAccelerationStructure

VkResult MVKCmdBuildAccelerationStructure::setContent(MVKCommandBuffer*                                       cmdBuff,
                                                      uint32_t                                                infoCount,
                                                      const VkAccelerationStructureBuildGeometryInfoKHR*      pInfos,
                                                      const VkAccelerationStructureBuildRangeInfoKHR* const*  ppBuildRangeInfos) {
    _buildInfos.reserve(infoCount);
    for (uint32_t i = 0; i < infoCount; i++)
    {
        MVKAccelerationStructureBuildInfo& info = _buildInfos.emplace_back();
        info.info = pInfos[i];

        // TODO: ppGeometries
        info.geometries.reserve(pInfos[i].geometryCount);
        info.ranges.reserve(pInfos[i].geometryCount);
        memcpy(info.geometries.data(), pInfos[i].pGeometries, pInfos[i].geometryCount);
        memcpy(info.ranges.data(), ppBuildRangeInfos[i], pInfos[i].geometryCount);

        info.info.pGeometries = info.geometries.data();
    }

    return VK_SUCCESS;
}

void MVKCmdBuildAccelerationStructure::encode(MVKCommandEncoder* cmdEncoder) {
    id<MTLAccelerationStructureCommandEncoder> accStructEncoder = cmdEncoder->getMTLAccelerationStructureEncoder(kMVKCommandUseBuildAccelerationStructure);
    
    for (MVKAccelerationStructureBuildInfo& entry : _buildInfos)
    {
        VkAccelerationStructureBuildGeometryInfoKHR& buildInfo = entry.info;

        MVKAccelerationStructure* mvkDstAccStruct = (MVKAccelerationStructure*)buildInfo.dstAccelerationStructure;

        id<MTLAccelerationStructure> dstAccStruct = mvkDstAccStruct->getMTLAccelerationStructure();
        
        // Should we throw an error here?
        // https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/vkCmdBuildAccelerationStructuresKHR.html#VUID-vkCmdBuildAccelerationStructuresKHR-pInfos-03667
        if(buildInfo.mode == VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR && !mvkDstAccStruct->getAllowUpdate())
            continue;
        
        MVKDevice* mvkDevice = cmdEncoder->getDevice();
        MVKBuffer* mvkBuffer = mvkDevice->getBufferAtAddress(buildInfo.scratchData.deviceAddress);

        // TODO: throw error if mvkBuffer is null?
        
        id<MTLBuffer> scratchBuffer = mvkBuffer->getMTLBuffer();
        NSInteger scratchBufferOffset = mvkBuffer->getMTLBufferOffset();
        
        if (buildInfo.mode == VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR)
        {
            MTLAccelerationStructureDescriptor* descriptor = mvkDstAccStruct->populateMTLDescriptor(
                mvkDevice,
                buildInfo,
                entry.ranges.data(),
                nullptr
            );

            [accStructEncoder buildAccelerationStructure:dstAccStruct
                                                descriptor:descriptor
                                                scratchBuffer:scratchBuffer
                                                scratchBufferOffset:scratchBufferOffset];
        }
        else if (buildInfo.mode == VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR)
        {
            MVKAccelerationStructure* mvkSrcAccStruct = (MVKAccelerationStructure*)buildInfo.srcAccelerationStructure;
            id<MTLAccelerationStructure> srcAccStruct = mvkSrcAccStruct->getMTLAccelerationStructure();

            MTLAccelerationStructureDescriptor* descriptor = [MTLAccelerationStructureDescriptor new];
            
            if (mvkIsAnyFlagEnabled(buildInfo.flags, VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT_KHR))
                descriptor.usage += MTLAccelerationStructureUsagePreferFastBuild;
            
            [accStructEncoder refitAccelerationStructure:srcAccStruct
                                              descriptor:descriptor
                                             destination:dstAccStruct
                                           scratchBuffer:scratchBuffer
                                     scratchBufferOffset:scratchBufferOffset];
        }
        mvkDstAccStruct->encodeCopyToSharedBuffer(cmdEncoder);
    }
}

#pragma mark -
#pragma mark MVKCmdCopyAccelerationStructure

VkResult MVKCmdCopyAccelerationStructure::setContent(MVKCommandBuffer*                  cmdBuff,
                                                     VkAccelerationStructureKHR         srcAccelerationStructure,
                                                     VkAccelerationStructureKHR         dstAccelerationStructure,
                                                     VkCopyAccelerationStructureModeKHR copyMode) {
    
    MVKAccelerationStructure* mvkSrcAccStruct = (MVKAccelerationStructure*)srcAccelerationStructure;
    MVKAccelerationStructure* mvkDstAccStruct = (MVKAccelerationStructure*)dstAccelerationStructure;
    
    _srcAccelerationStructure = mvkSrcAccStruct->getMTLAccelerationStructure();
    _dstAccelerationStructure = mvkDstAccStruct->getMTLAccelerationStructure();
    _copyMode = copyMode;
    return VK_SUCCESS;
}

void MVKCmdCopyAccelerationStructure::encode(MVKCommandEncoder* cmdEncoder) {
    id<MTLAccelerationStructureCommandEncoder> accStructEncoder = cmdEncoder->getMTLAccelerationStructureEncoder(kMVKCommandUseCopyAccelerationStructure);
    if(_copyMode == VK_COPY_ACCELERATION_STRUCTURE_MODE_COMPACT_KHR)
    {
        [accStructEncoder
         copyAndCompactAccelerationStructure:_srcAccelerationStructure
         toAccelerationStructure:_dstAccelerationStructure];
        
        return;
    }
    
    [accStructEncoder
         copyAccelerationStructure:_srcAccelerationStructure
         toAccelerationStructure:_dstAccelerationStructure];
}

#pragma mark -
#pragma mark MVKCmdCopyAccelerationStructureToMemory

//static constexpr uint32_t MVK_ACCELERATION_STRUCTURE_SERIALIZATION_VERSION = MVK_MAKE_VERSION(1, 0, 0);

static std::size_t GetSerializedAccelerationStructureSize(MVKAccelerationStructure* mvkAS)
{
    std::size_t blasCount = 0;
    std::size_t asSize = 768;

    // Size of the serialized acceleration structure header.
    std::size_t headerSize =
        VK_UUID_SIZE + // VkPhysicalDeviceIDPropertiesKHR::deviceUUID
        VK_UUID_SIZE + // MVK AS Serialization Version
        sizeof(uint64_t) + // Total Serialization Size
        sizeof(uint64_t) + // Total Deserialized Size
        sizeof(uint64_t) + // BLAS Handle Count
        sizeof(uint64_t) * blasCount + // BLAS Handles
        asSize; // Size of the acceleration structure data

    return headerSize;
}

static std::vector<uint8_t> CreateSerializedAccelerationStructure(MVKAccelerationStructure* mvkAS)
{
    uint64_t serializedSize = (uint64_t)GetSerializedAccelerationStructureSize(mvkAS);
    uint64_t deserializedSize = 768;
    uint64_t blasHandleCount = 0;

    std::vector<uint8_t> serializedData(serializedSize);
    uint8_t* pData = serializedData.data();

    uint8_t driverUUID[VK_UUID_SIZE]{};
    uint8_t accStrVersion[VK_UUID_SIZE]{};

    memcpy(pData, &driverUUID, VK_UUID_SIZE);
    pData += VK_UUID_SIZE;

    memcpy(pData, &accStrVersion, VK_UUID_SIZE);
    pData += VK_UUID_SIZE;

    memcpy(pData, &serializedSize, sizeof(uint64_t));
    pData += sizeof(uint64_t);

    memcpy(pData, &deserializedSize, sizeof(uint64_t));
    pData += sizeof(uint64_t);

    memcpy(pData, &blasHandleCount, sizeof(uint64_t));
    pData += sizeof(uint64_t);

    memset(pData, 0, sizeof(uint64_t) * blasHandleCount); // Fill with BLAS handles (if any)
    pData += sizeof(uint64_t) * blasHandleCount;

    memset(pData, 0, deserializedSize); // Fill the rest with zeros (or actual data if available)
    pData += deserializedSize;

    pData = serializedData.data();
    pData += VK_UUID_SIZE * 2 + sizeof(uint64_t);

    return serializedData;
}

VkResult MVKCmdCopyAccelerationStructureToMemory::setContent(MVKCommandBuffer*                  cmdBuff,
                                                             VkAccelerationStructureKHR         srcAccelerationStructure,
                                                             uint64_t                           dstAddress,
                                                             VkCopyAccelerationStructureModeKHR copyMode) {
    _dstAddress = dstAddress;
    _copyMode = copyMode;
    
    _srcAccelerationStructure = (MVKAccelerationStructure*)srcAccelerationStructure;

    auto serializedData = CreateSerializedAccelerationStructure(_srcAccelerationStructure);

    _copySize = serializedData.size();

    auto* device = cmdBuff->getDevice();

    _stagingBuffer = [cmdBuff->getMTLDevice() newBufferWithBytes: serializedData.data()
                                                          length: _copySize
                                                         options: MTLResourceStorageModeShared];

    _dstBuffer = device->getBufferAtAddress(_dstAddress);
    return VK_SUCCESS;
}
                                        
void MVKCmdCopyAccelerationStructureToMemory::encode(MVKCommandEncoder* cmdEncoder) {
    id<MTLBlitCommandEncoder> blitEncoder = cmdEncoder->getMTLBlitEncoder(kMVKCommandUseCopyAccelerationStructureToMemory);

    [blitEncoder copyFromBuffer: _stagingBuffer
                   sourceOffset: 0
                       toBuffer: _dstBuffer->getMTLBuffer()
              destinationOffset: 0
                           size: _copySize];
}

#pragma mark -
#pragma mark MVKCmdCopyMemoryToAccelerationStructure

VkResult MVKCmdCopyMemoryToAccelerationStructure::setContent(MVKCommandBuffer* cmdBuff,
                                                             uint64_t srcAddress,
                                                             VkAccelerationStructureKHR dstAccelerationStructure,
                                                             VkCopyAccelerationStructureModeKHR copyMode) {
    _srcAddress = srcAddress;
    _copyMode = copyMode;
    
    _srcBuffer = cmdBuff->getDevice()->getBufferAtAddress(_srcAddress);
    
    MVKAccelerationStructure* mvkDstAccStruct = (MVKAccelerationStructure*)dstAccelerationStructure;
    _dstAccelerationStructure = mvkDstAccStruct->getMTLAccelerationStructure();
    _dstAccelerationStructureBuffer = mvkDstAccStruct->getMTLBuffer();
    return VK_SUCCESS;
}

void MVKCmdCopyMemoryToAccelerationStructure::encode(MVKCommandEncoder* cmdEncoder) {
    id<MTLBlitCommandEncoder> blitEncoder = cmdEncoder->getMTLBlitEncoder(kMVKCommandUseCopyAccelerationStructureToMemory);
    _mvkDevice = cmdEncoder->getDevice();
    
    [blitEncoder copyFromBuffer:_srcBuffer->getMTLBuffer() sourceOffset:0 toBuffer:_dstAccelerationStructureBuffer destinationOffset:0 size:_copySize];
}

#pragma mark -
#pragma mark MVKCmdWriteAccelerationStructuresProperties

VkResult MVKCmdWriteAccelerationStructuresProperties::setContent(MVKCommandBuffer* cmdBuff,
                    uint32_t accelerationStructureCount,
                    const VkAccelerationStructureKHR* pAccelerationStructures,
                    VkQueryType queryType,
                    VkQueryPool queryPool,
                    uint32_t firstQuery) {

    VkResult rslt = MVKCmdQuery::setContent(cmdBuff, queryPool, firstQuery);

    _accelerationStructureCount = accelerationStructureCount;
    _accelerationStructures.clear();
    _accelerationStructures.reserve(accelerationStructureCount);
    for (uint32_t i = 0; i < accelerationStructureCount; i++) {
        auto* mvkAS = (MVKAccelerationStructure*)pAccelerationStructures[i];
        _accelerationStructures.push_back(mvkAS);
    }
    _queryType = queryType;
    return rslt;
}

void MVKCmdWriteAccelerationStructuresProperties::encode(MVKCommandEncoder* cmdEncoder) {

    switch(_queryType)
    {
        case VK_QUERY_TYPE_ACCELERATION_STRUCTURE_SIZE_KHR:
            break;
        case VK_QUERY_TYPE_ACCELERATION_STRUCTURE_SERIALIZATION_BOTTOM_LEVEL_POINTERS_KHR:
            break;
        case VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR: {
            id<MTLAccelerationStructureCommandEncoder> accStructEncoder = cmdEncoder->getMTLAccelerationStructureEncoder(kMVKCommandUseWriteAccelerationStructuresProperties);
            auto* queryPool = (MVKAccelerationStructureCompactedSizeQueryPool*)_queryPool;
            id<MTLBuffer> resultsBuffer = queryPool->getResultsBuffer();
            for (uint32_t i = 0; i < _accelerationStructureCount; i++) {
                MVKAccelerationStructure* mvkAS = _accelerationStructures[i];
                if (!mvkAS) { continue; }

                id<MTLAccelerationStructure> mtlAS = mvkAS->getMTLAccelerationStructure();
                if (!mtlAS) { continue; }


                auto queryOffset = (_query + i) * sizeof(uint64_t);

                [accStructEncoder writeCompactedAccelerationStructureSize:mtlAS
                                                                 toBuffer:resultsBuffer
                                                                   offset:queryOffset
                                                             sizeDataType:MTLDataTypeULong];
            }
        }
            break;
        case VK_QUERY_TYPE_ACCELERATION_STRUCTURE_SERIALIZATION_SIZE_KHR: {
            id<MTLBlitCommandEncoder> blitEncoder = cmdEncoder->getMTLBlitEncoder(kMVKCommandUseCopyQueryPoolResults);
            auto* queryPool = (MVKAccelerationStructureSerializationSizeQueryPool*)_queryPool;
            id<MTLBuffer> resultsBuffer = queryPool->getResultsBuffer();
            for (uint32_t i = 0; i < _accelerationStructureCount; i++) {
                MVKAccelerationStructure* mvkAS = _accelerationStructures[i];
                if (!mvkAS) { continue; }

                id<MTLAccelerationStructure> mtlAS = mvkAS->getMTLAccelerationStructure();
                if (!mtlAS) { continue; }

                auto queryOffset = (_query + i) * sizeof(uint64_t);

                uint64_t serializationSize = GetSerializedAccelerationStructureSize(mvkAS);

                const MVKMTLBufferAllocation* tempAlloc = cmdEncoder->copyToTempMTLBufferAllocation(&serializationSize, sizeof(serializationSize));

                [blitEncoder copyFromBuffer: tempAlloc->_mtlBuffer
                               sourceOffset: tempAlloc->_offset
                                   toBuffer: resultsBuffer
                          destinationOffset: queryOffset
                                       size: sizeof(uint64_t)];
            }     
        }
            break;
        default:
            break;
    }
    cmdEncoder->writeAccelerationStructureProperties(_queryPool,
                                                     _query,
                                                     _accelerationStructureCount,
                                                     _queryType,
                                                     MVKArrayRef{_accelerationStructures.data(), _accelerationStructures.size()});
}
