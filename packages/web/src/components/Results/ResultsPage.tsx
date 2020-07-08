import React from 'react'

import styled from 'styled-components'

import { LayoutResults } from 'src/components/Layout/LayoutResults'
import { GeneMapTable } from 'src/components/GeneMap/GeneMapTable'

import { ButtonBack } from './ButtonBack'
import { ButtonExport } from './ButtonExport'
import { ResultsStatus } from './ResultsStatus'
import { ResultsTable } from './ResultsTable'

export const Container = styled.div`
  width: 100%;
  height: 100%;
  min-width: 740px;
  display: flex;
  flex-direction: column;
  flex-wrap: nowrap;
`

const Header = styled.header`
  flex-shrink: 0;
  display: flex;
`

const HeaderLeft = styled.header`
  flex: 0;
`

const HeaderCenter = styled.header`
  flex: 1;
  padding: 5px 10px;
  border-radius: 5px;
`

const HeaderRight = styled.header`
  flex: 0;
`

const MainContent = styled.main`
  flex-grow: 1;
  overflow: auto;
  border: 1px solid #b3b3b3aa;
`

const Footer = styled.footer`
  flex-shrink: 0;
`

export function ResultsPage() {
  return (
    <LayoutResults>
      <Container>
        <Header>
          <HeaderLeft>
            <ButtonBack />
          </HeaderLeft>
          <HeaderCenter>
            <ResultsStatus />
          </HeaderCenter>
          <HeaderRight>
            <ButtonExport />
          </HeaderRight>
        </Header>

        <MainContent>
          <ResultsTable />
        </MainContent>

        <Footer>
          <GeneMapTable />
        </Footer>
      </Container>
    </LayoutResults>
  )
}
